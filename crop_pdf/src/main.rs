use lopdf::Object;
use std::env;
use std::fs;

fn mm2pt(v: f64) -> f64 {
    v * 72.0 / 25.4
}

fn parse(args: &[String], i: usize) -> f64 {
    args[i].parse().unwrap_or(0.0)
}

/// Read actual_printable_bounds from a DWG To PDF.pc3 JSON file.
fn read_hw_margins(pc3_path: &str) -> (f64, f64) {
    let text = fs::read_to_string(pc3_path).unwrap_or_default();
    // Strip the "PIAFILEVERSION_3.0,json\n" header
    if let Some(pos) = text.find('{') {
        let json: serde_json::Value =
            serde_json::from_str(&text[pos..]).unwrap_or(serde_json::Value::Null);
        if let Some(media) = json.pointer("/data/media") {
            let llx = media
                .get("actual_printable_bounds_llx")
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0);
            let lly = media
                .get("actual_printable_bounds_lly")
                .and_then(|v| v.as_f64())
                .unwrap_or(0.0);
            return (llx, lly);
        }
    }
    (0.0, 0.0)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 7 {
        eprintln!(
            "Usage: crop_pdf <PDF> <minx> <miny> <maxx> <maxy> <margin> [pc3_path] [pad_tr]"
        );
        std::process::exit(1);
    }

    let pdf_path = &args[1];
    let minx = parse(&args, 2);
    let miny = parse(&args, 3);
    let maxx = parse(&args, 4);
    let maxy = parse(&args, 5);
    let margin = parse(&args, 6);

    // Read hardware margins from PC3 if provided
    let (hw_left, hw_bottom) = if args.len() > 7 && !args[7].is_empty() {
        read_hw_margins(&args[7])
    } else {
        (0.0, 0.0)
    };

    let pad_tr = if args.len() > 8 { parse(&args, 8) } else { 0.5 };
    let pad_lb = if args.len() > 9 { parse(&args, 9) } else { 0.3 };
    let voff = if args.len() > 10 { parse(&args, 10) } else { 0.0 };

    let off_x = (margin + hw_left - pad_lb) * mm2pt(1.0);
    let off_y = (margin + hw_bottom - pad_lb + voff) * mm2pt(1.0);
    let w = (maxx - minx) * mm2pt(1.0);
    let h = (maxy - miny) * mm2pt(1.0);
    let pad = pad_tr * mm2pt(1.0);

    let left = ((off_x * 100.0).round() / 100.0) as f32;
    let bottom = ((off_y * 100.0).round() / 100.0) as f32;
    let right = (((off_x + w + pad) * 100.0).round() / 100.0) as f32;
    let top = (((off_y + h + pad) * 100.0).round() / 100.0) as f32;

    let mut doc = lopdf::Document::load(pdf_path).expect("Failed to load PDF");

    let page_id = doc
        .get_pages()
        .get(&1_u32)
        .copied()
        .expect("No page found");

    let rect = Object::Array(vec![
        Object::Real(left),
        Object::Real(bottom),
        Object::Real(right),
        Object::Real(top),
    ]);

    if let Some(obj) = doc.objects.get_mut(&page_id) {
        if let Ok(dict) = obj.as_dict_mut() {
            dict.set("MediaBox", rect.clone());
            dict.set("CropBox", rect);
        }
    }

    let tmp = format!("{}.tmp", pdf_path);
    doc.save(&tmp).expect("Failed to save");
    fs::rename(&tmp, pdf_path).expect("Failed to replace");
}

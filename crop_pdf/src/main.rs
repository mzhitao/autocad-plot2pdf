use lopdf::Object;
use std::env;
use std::fs;

fn mm2pt(v: f64) -> f64 {
    v * 72.0 / 25.4
}

fn parse(args: &[String], i: usize) -> f64 {
    args[i].parse().unwrap_or(0.0)
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 7 {
        eprintln!("Usage: crop_pdf <PDF> <minx> <miny> <maxx> <maxy> <margin> [comp] [pad_tr]");
        std::process::exit(1);
    }

    let pdf_path = &args[1];
    let minx = parse(&args, 2);
    let miny = parse(&args, 3);
    let maxx = parse(&args, 4);
    let maxy = parse(&args, 5);
    let margin = parse(&args, 6);
    let comp = if args.len() > 7 { parse(&args, 7) } else { 0.5 };
    let pad_tr = if args.len() > 8 { parse(&args, 8) } else { 0.5 };

    let off = (margin - comp) * mm2pt(1.0);
    let w = (maxx - minx) * mm2pt(1.0);
    let h = (maxy - miny) * mm2pt(1.0);
    let pad = pad_tr * mm2pt(1.0);

    let left = ((off * 100.0).round() / 100.0) as f32;
    let bottom = ((off * 100.0).round() / 100.0) as f32;
    let right = (((off + w + pad) * 100.0).round() / 100.0) as f32;
    let top = (((off + h + pad) * 100.0).round() / 100.0) as f32;

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

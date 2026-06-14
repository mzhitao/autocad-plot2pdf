mod emf;

use lopdf::content::Content;
use lopdf::{Document, Object, ObjectId};
use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::Path;

fn mm2pt(v: f64) -> f64 {
    v * 72.0 / 25.4
}

fn xf(ctm: &[f64; 6], x: f64, y: f64) -> (f64, f64) {
    (ctm[0] * x + ctm[2] * y + ctm[4], ctm[1] * x + ctm[3] * y + ctm[5])
}

fn concat_ctm(ctm: &mut [f64; 6], a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) {
    let a1 = ctm[0];
    let b1 = ctm[1];
    let c1 = ctm[2];
    let d1 = ctm[3];
    let e1 = ctm[4];
    let f1 = ctm[5];
    ctm[0] = a1 * a + b1 * c;
    ctm[1] = a1 * b + b1 * d;
    ctm[2] = c1 * a + d1 * c;
    ctm[3] = c1 * b + d1 * d;
    ctm[4] = e1 * a + f1 * c + e;
    ctm[5] = e1 * b + f1 * d + f;
}

fn of32(o: &Object) -> f64 {
    o.as_float().unwrap_or(0.0) as f64
}

fn resolve_stream(doc: &Document, obj: &Object) -> Option<(Vec<u8>, lopdf::Dictionary)> {
    match obj {
        Object::Reference(id) => {
            let obj = doc.get_object(*id).ok()?;
            match obj {
                Object::Stream(s) => Some((s.content.clone(), s.dict.clone())),
                _ => None,
            }
        }
        Object::Stream(s) => Some((s.content.clone(), s.dict.clone())),
        _ => None,
    }
}

fn dump_ops(bytes: &[u8], depth: usize) {
    if let Ok(content) = Content::decode(bytes) {
        let indent = "  ".repeat(depth);
        for (i, op) in content.operations.iter().enumerate().take(30) {
            let args: Vec<String> = op.operands.iter().map(|o| {
                if let Ok(s) = o.as_name() {
                    format!("/{}", String::from_utf8_lossy(s))
                } else if let Ok(f) = o.as_float() {
                    format!("{:.2}", f)
                } else {
                    format!("{:?}", o)
                }
            }).collect();
            eprintln!("{}{}: {}{}", indent, i, op.operator, if args.is_empty() { String::new() } else { format!(" {}", args.join(" ")) });
        }
        if content.operations.len() > 30 {
            eprintln!("{}... ({} total ops)", indent, content.operations.len());
        }
    }
}

fn process_content(
    doc: &Document,
    bytes: &[u8],
    resources: Option<&lopdf::Dictionary>,
    initial_ctm: [f64; 6],
    depth: usize,
    dump: bool,
) -> Option<(f64, f64, f64, f64)> {
    let content = Content::decode(bytes).ok()?;
    let mut min_x = f64::MAX;
    let mut min_y = f64::MAX;
    let mut max_x = f64::MIN;
    let mut max_y = f64::MIN;
    let mut found = false;
    let mut ctm_stack: Vec<[f64; 6]> = vec![initial_ctm];

    let mut tm: [f64; 6] = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];

    let xobj_lookup = resources
        .and_then(|r| r.get(b"XObject").ok()?.as_dict().ok())
        .map(|d| {
            eprintln!("{}XObjects:", "  ".repeat(depth));
            for (key, val) in d.iter() {
                let val_str = match val {
                    Object::Reference(id) => format!("ref {}.{}", id.0, id.1),
                    Object::Stream(_) => "stream".to_string(),
                    _ => format!("{:?}", val),
                };
                eprintln!("{}  /{} -> {}", "  ".repeat(depth), String::from_utf8_lossy(key), val_str);
            }
            d
        });

    let indent = "  ".repeat(depth);

    if dump {
        eprintln!("{}Operations:", indent);
        dump_ops(bytes, depth + 1);
    }

    macro_rules! track {
        ($x:expr, $y:expr) => {{
            let (tx, ty) = xf(ctm_stack.last().unwrap(), $x, $y);
            if tx < min_x { min_x = tx; found = true; }
            if ty < min_y { min_y = ty; found = true; }
            if tx > max_x { max_x = tx; found = true; }
            if ty > max_y { max_y = ty; found = true; }
        }};
    }

    for op in &content.operations {
        match op.operator.as_str() {
            "cm" if op.operands.len() >= 6 => {
                let ctm = ctm_stack.last_mut().unwrap();
                concat_ctm(ctm,
                    of32(&op.operands[0]), of32(&op.operands[1]),
                    of32(&op.operands[2]), of32(&op.operands[3]),
                    of32(&op.operands[4]), of32(&op.operands[5]),
                );
            }
            "q" => {
                if let Some(ctm) = ctm_stack.last() {
                    ctm_stack.push(*ctm);
                }
            }
            "Q" => {
                ctm_stack.pop();
                if ctm_stack.is_empty() {
                    ctm_stack.push([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);
                }
            }
            "m" | "l" if op.operands.len() >= 2 => {
                track!(of32(&op.operands[0]), of32(&op.operands[1]));
            }
            "c" if op.operands.len() >= 6 => {
                for i in (0..6).step_by(2) {
                    track!(of32(&op.operands[i]), of32(&op.operands[i + 1]));
                }
            }
            "v" | "y" if op.operands.len() >= 4 => {
                for i in (0..4).step_by(2) {
                    track!(of32(&op.operands[i]), of32(&op.operands[i + 1]));
                }
            }
            "re" if op.operands.len() >= 4 => {
                let x = of32(&op.operands[0]);
                let y = of32(&op.operands[1]);
                let w = of32(&op.operands[2]);
                let h = of32(&op.operands[3]);
                track!(x, y);
                track!(x + w, y + h);
            }
            "BT" => {
                tm = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
            }
            "Td" | "TD" if op.operands.len() >= 2 => {
                let tx = of32(&op.operands[0]);
                let ty = of32(&op.operands[1]);
                tm[4] += tx;
                tm[5] += ty;
                track!(tm[4], tm[5]);
            }
            "Tm" if op.operands.len() >= 6 => {
                tm = [
                    of32(&op.operands[0]), of32(&op.operands[1]),
                    of32(&op.operands[2]), of32(&op.operands[3]),
                    of32(&op.operands[4]), of32(&op.operands[5]),
                ];
                track!(tm[4], tm[5]);
            }
            "Tj" | "'" | "\"" | "TJ" => {
                track!(tm[4], tm[5]);
            }
            "Do" => {
                if let Some(xobj_dict) = xobj_lookup {
                    if let Ok(name) = op.operands.first().ok_or(()).and_then(|o| o.as_name().map_err(|_| ())) {
                        if let Ok(xobj_ref) = xobj_dict.get(name) {
                            if let Some((child_bytes, child_dict)) = resolve_stream(doc, xobj_ref) {
                                let subtype = child_dict.get(b"Subtype").ok().and_then(|o| o.as_name().ok());
                                let name_str = String::from_utf8_lossy(name);
                                if subtype == Some(b"Form") {
                                    eprintln!("{}Do /{} (Form)", indent, name_str);
                                    let cur_ctm = *ctm_stack.last().unwrap();
                                    let mut form_ctm = cur_ctm;
                                    if let Ok(matrix) = child_dict.get(b"Matrix") {
                                        if let Ok(arr) = matrix.as_array() {
                                            if arr.len() >= 6 {
                                                concat_ctm(&mut form_ctm,
                                                    of32(&arr[0]), of32(&arr[1]),
                                                    of32(&arr[2]), of32(&arr[3]),
                                                    of32(&arr[4]), of32(&arr[5]),
                                                );
                                            }
                                        }
                                    }
                                    let child_res = child_dict.get(b"Resources").ok().and_then(|r| r.as_dict().ok());
                                    if let Some(fb) = process_content(doc, &child_bytes, child_res, form_ctm, depth + 1, dump) {
                                        min_x = min_x.min(fb.0);
                                        min_y = min_y.min(fb.1);
                                        max_x = max_x.max(fb.2);
                                        max_y = max_y.max(fb.3);
                                        found = true;
                                    } else {
                                        eprintln!("{}Form XObject '{}': no content found", indent, name_str);
                                    }
                                } else if subtype == Some(b"Image") {
                                    eprintln!("{}Do /{} (Image)", indent, name_str);
                                    if let Ok(dim_arr) = child_dict.get(b"Width") {
                                        let w = dim_arr.as_float().unwrap_or(0.0) as f64;
                                        let h = child_dict.get(b"Height").ok().and_then(|o| o.as_float().ok()).unwrap_or(0.0) as f64;
                                        track!(0.0, 0.0);
                                        track!(w, h);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }

    if found {
        eprintln!("{}bbox: ({:.1}, {:.1}) \u{2192} ({:.1}, {:.1})  ({} ops)", indent, min_x, min_y, max_x, max_y, content.operations.len());
    } else {
        eprintln!("{}NO CONTENT FOUND ({} ops)", indent, content.operations.len());
    }

    found.then_some((min_x, min_y, max_x, max_y))
}

fn page_content_bytes(doc: &Document, page_id: ObjectId) -> Option<Vec<u8>> {
    let page_obj = doc.objects.get(&page_id)?;
    let page_dict = page_obj.as_dict().ok()?;
    let contents = page_dict.get(b"Contents").ok()?;
    let raw = |o: &Object| -> Option<Vec<u8>> {
        match o {
            Object::Reference(id) => {
                doc.get_object(*id).ok()?.as_stream().ok().map(|s| s.content.clone())
            }
            Object::Stream(stream) => Some(stream.content.clone()),
            _ => None,
        }
    };
    match contents {
        Object::Reference(_) => raw(contents),
        Object::Array(arr) => {
            let mut buf = Vec::new();
            for item in arr {
                if let Some(bytes) = raw(item) {
                    buf.extend_from_slice(&bytes);
                }
            }
            Some(buf)
        }
        Object::Stream(_) => raw(contents),
        _ => None,
    }
}

fn page_resources(doc: &Document, page_id: ObjectId) -> Option<lopdf::Dictionary> {
    let dict = doc.objects.get(&page_id)?.as_dict().ok()?;
    let res = dict.get(b"Resources").ok()?;
    match res {
        Object::Reference(id) => doc.get_object(*id).ok()?.as_dict().ok().cloned(),
        Object::Dictionary(d) => Some(d.clone()),
        _ => None,
    }
}

#[allow(unused_assignments)]
fn content_to_emf(
    doc: &Document,
    bytes: &[u8],
    resources: Option<&lopdf::Dictionary>,
    emf: &mut emf::Emf,
    initial_ctm: [f64; 6],
    depth: usize,
) {
    let content = match Content::decode(bytes) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut ctm_stack: Vec<[f64; 6]> = vec![initial_ctm];
    let mut in_path = false;

    let xobj_lookup = resources
        .and_then(|r| r.get(b"XObject").ok()?.as_dict().ok());

    for op in &content.operations {
        match op.operator.as_str() {
            "cm" if op.operands.len() >= 6 => {
                let ctm = ctm_stack.last_mut().unwrap();
                concat_ctm(ctm,
                    of32(&op.operands[0]), of32(&op.operands[1]),
                    of32(&op.operands[2]), of32(&op.operands[3]),
                    of32(&op.operands[4]), of32(&op.operands[5]),
                );
            }
            "q" => {
                if in_path { emf.endpath(); in_path = false; }
                emf.savedc();
                if let Some(ctm) = ctm_stack.last() {
                    ctm_stack.push(*ctm);
                }
            }
            "Q" => {
                if in_path { emf.endpath(); in_path = false; }
                emf.restoredc();
                ctm_stack.pop();
                if ctm_stack.is_empty() {
                    ctm_stack.push([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]);
                }
            }
            "m" if op.operands.len() >= 2 => {
                if in_path { emf.endpath(); in_path = false; }
                let (x, y) = {
                    let ctm = ctm_stack.last().unwrap();
                    xf(ctm, of32(&op.operands[0]), of32(&op.operands[1]))
                };
                emf.beginpath();
                emf.moveto(x, y);
                in_path = true;
            }
            "l" if op.operands.len() >= 2 => {
                let (x, y) = {
                    let ctm = ctm_stack.last().unwrap();
                    xf(ctm, of32(&op.operands[0]), of32(&op.operands[1]))
                };
                emf.lineto(x, y);
            }
            "c" if op.operands.len() >= 6 => {
                let ctm = ctm_stack.last().unwrap();
                let p1 = xf(ctm, of32(&op.operands[0]), of32(&op.operands[1]));
                let p2 = xf(ctm, of32(&op.operands[2]), of32(&op.operands[3]));
                let p3 = xf(ctm, of32(&op.operands[4]), of32(&op.operands[5]));
                emf.curveto(p1.0, p1.1, p2.0, p2.1, p3.0, p3.1);
            }
            "v" if op.operands.len() >= 4 => {
                let ctm = ctm_stack.last().unwrap();
                let p2 = xf(ctm, of32(&op.operands[0]), of32(&op.operands[1]));
                let p3 = xf(ctm, of32(&op.operands[2]), of32(&op.operands[3]));
                let p1 = xf(ctm, 0.0, 0.0);
                emf.curveto(p1.0, p1.1, p2.0, p2.1, p3.0, p3.1);
            }
            "y" if op.operands.len() >= 4 => {
                let ctm = ctm_stack.last().unwrap();
                let p2 = xf(ctm, of32(&op.operands[0]), of32(&op.operands[1]));
                let p3 = xf(ctm, of32(&op.operands[2]), of32(&op.operands[3]));
                emf.curveto(p2.0, p2.1, p2.0, p2.1, p3.0, p3.1);
            }
            "re" if op.operands.len() >= 4 => {
                let ctm = ctm_stack.last().unwrap();
                let mut x = of32(&op.operands[0]);
                let mut y = of32(&op.operands[1]);
                let w = of32(&op.operands[2]);
                let h = of32(&op.operands[3]);
                let p1 = xf(ctm, x, y);
                let p2 = xf(ctm, x + w, y + h);
                x = p1.0.min(p2.0);
                y = p1.1.min(p2.1);
                let w2 = (p2.0 - p1.0).abs();
                let h2 = (p2.1 - p1.1).abs();
                emf.rect(x, y, w2, h2);
            }
            "h" => {
                emf.closefig();
            }
            "S" | "s" => {
                if in_path { emf.endpath(); in_path = false; }
                emf.stroke();
            }
            "f" | "F" | "f*" => {
                if in_path { emf.endpath(); in_path = false; }
                emf.fill();
            }
            "B" | "B*" | "b" | "b*" => {
                if in_path { emf.endpath(); in_path = false; }
                emf.fillstroke();
            }
            "n" => {
                if in_path { emf.endpath(); in_path = false; }
            }
            "Do" => {
                if in_path { emf.endpath(); in_path = false; }
                if let Some(xobj_dict) = xobj_lookup {
                    if let Ok(name) = op.operands.first().ok_or(()).and_then(|o| o.as_name().map_err(|_| ())) {
                        if let Ok(xobj_ref) = xobj_dict.get(name) {
                            if let Some((child_bytes, child_dict)) = resolve_stream(doc, xobj_ref) {
                                let subtype = child_dict.get(b"Subtype").ok().and_then(|o| o.as_name().ok());
                                if subtype == Some(b"Form") {
                                    let mut form_ctm = *ctm_stack.last().unwrap();
                                    if let Ok(matrix) = child_dict.get(b"Matrix") {
                                        if let Ok(arr) = matrix.as_array() {
                                            if arr.len() >= 6 {
                                                concat_ctm(&mut form_ctm,
                                                    of32(&arr[0]), of32(&arr[1]),
                                                    of32(&arr[2]), of32(&arr[3]),
                                                    of32(&arr[4]), of32(&arr[5]),
                                                );
                                            }
                                        }
                                    }
                                    let child_res = child_dict.get(b"Resources").ok().and_then(|r| r.as_dict().ok());
                                    content_to_emf(doc, &child_bytes, child_res, emf, form_ctm, depth + 1);
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
    if in_path { emf.endpath(); }
}

fn export_emf(doc: &Document, pdf_path: &str) {
    let pages = doc.get_pages();
    let pdf_stem = Path::new(pdf_path).file_stem().unwrap().to_str().unwrap();

    for (&num, &page_id) in &pages {
        let pw_ph = (|| -> Option<(f64, f64)> {
            let obj = doc.objects.get(&page_id)?;
            let dict = obj.as_dict().ok()?;
            let mb = dict.get(b"MediaBox").ok()?;
            let arr = mb.as_array().ok()?;
            let v: Vec<f32> = arr.iter().filter_map(|o| o.as_float().ok()).collect();
            if v.len() >= 4 { Some(((v[2] - v[0]) as f64, (v[3] - v[1]) as f64)) } else { None }
        })().unwrap_or((841.0, 1189.0));
        let (pw, ph) = pw_ph;

        let out_path = if pages.len() > 1 {
            format!("{}-p{}.emf", pdf_stem, num)
        } else {
            format!("{}.emf", pdf_stem)
        };

        eprintln!("  Page {} -> {}", num, out_path);

        let mut emf = emf::Emf::new(pw, ph);

        if let Some(bytes) = page_content_bytes(doc, page_id) {
            let resources = page_resources(doc, page_id);
            content_to_emf(doc, &bytes, resources.as_ref(), &mut emf, [1.0, 0.0, 0.0, 1.0, 0.0, 0.0], 1);
        }

        if let Err(e) = emf.save(&out_path) {
            eprintln!("  ERROR writing EMF: {}", e);
        } else {
            eprintln!("  Wrote {}", out_path);
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: crop_pdf <PDF> [padding_mm] [--dump|--scan|--emf]");
        std::process::exit(1);
    }

    let pdf_path = &args[1];
    let padding_mm = if args.len() > 2 && !args[2].starts_with("--") {
        args[2].parse::<f64>().unwrap_or(1.0)
    } else {
        1.0
    };
    let dump = args.iter().any(|a| a == "--dump");
    let scan = args.iter().any(|a| a == "--scan");
    let emf_mode = args.iter().any(|a| a == "--emf");
    let pad_pt = mm2pt(padding_mm) as f32;

    eprintln!("=== crop_pdf: {} (padding={}mm){} ===", pdf_path, padding_mm,
        if scan { " --scan" } else if emf_mode { " --emf" } else if dump { " --dump" } else { "" });

    let mut doc = Document::load(pdf_path).expect("Failed to load PDF");
    doc.decompress();

    // --scan: dump all objects
    if scan {
        for (&_num, &page_id) in &doc.get_pages() {
            if let Some(bytes) = page_content_bytes(&doc, page_id) {
                eprintln!("\n--- Page content (raw text) ---");
                let text = String::from_utf8_lossy(&bytes);
                for line in text.lines() {
                    eprintln!("{}", line);
                }
            }
        }
        for (id, obj) in &doc.objects {
            if let Some(stream) = obj.as_stream().ok() {
                if stream.content.len() > 10000 {
                    eprintln!("\n--- Large stream obj {}.{} ({}B) ---", id.0, id.1, stream.content.len());
                    let text = String::from_utf8_lossy(&stream.content[..stream.content.len().min(500)]);
                    if text.contains('m') || text.contains('l') || text.contains('c') || text.contains("re") {
                        eprintln!("  Contains path operators — likely Form content");
                        for line in text.lines().take(20) {
                            eprintln!("  {}", line);
                        }
                    } else {
                        eprintln!("  Binary/encoded — first 200 bytes hex:");
                        for chunk in stream.content[..stream.content.len().min(200)].chunks(32) {
                            let hex: String = chunk.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>().join(" ");
                            let ascii: String = chunk.iter().map(|&b| if b.is_ascii_graphic() || b == b' ' { b as char } else { '.' }).collect();
                            eprintln!("  {}  {}", hex, ascii);
                        }
                    }
                }
            }
        }
        eprintln!("--- All objects ---");
        let mut sorted_ids: Vec<_> = doc.objects.keys().collect();
        sorted_ids.sort();
        for id in sorted_ids {
            let obj = &doc.objects[id];
            if let Ok(dict) = obj.as_dict() {
                let mut info = String::new();
                if let Ok(t) = dict.get(b"Type") {
                    if let Ok(name) = t.as_name() {
                        info.push_str(&format!(" /Type={}", String::from_utf8_lossy(name)));
                    }
                }
                if let Ok(s) = dict.get(b"Subtype") {
                    if let Ok(name) = s.as_name() {
                        info.push_str(&format!(" /Subtype={}", String::from_utf8_lossy(name)));
                    }
                }
                if let Ok(mb) = dict.get(b"MediaBox") {
                    if let Ok(arr) = mb.as_array() {
                        let v: Vec<f32> = arr.iter().filter_map(|o| o.as_float().ok()).collect();
                        if v.len() >= 4 {
                            info.push_str(&format!(" MediaBox=[{:.1} {:.1} {:.1} {:.1}]", v[0], v[1], v[2], v[3]));
                        }
                    }
                }
                if let Ok(c) = dict.get(b"Contents") {
                    info.push_str(&format!(" /Contents={:?}", c));
                }
                if let Ok(r) = dict.get(b"Resources") {
                    info.push_str(&format!(" /Resources={:?}", r));
                }
                eprintln!("  obj {}.{}: dict{{{}}}", id.0, id.1, info);
            } else if let Ok(stream) = obj.as_stream() {
                let dict = &stream.dict;
                let len = stream.content.len();
                let mut info = format!("stream {}B", len);
                if let Ok(t) = dict.get(b"Type") {
                    if let Ok(name) = t.as_name() {
                        info.push_str(&format!(" /Type={}", String::from_utf8_lossy(name)));
                    }
                }
                if let Ok(s) = dict.get(b"Subtype") {
                    if let Ok(name) = s.as_name() {
                        info.push_str(&format!(" /Subtype={}", String::from_utf8_lossy(name)));
                    }
                }
                if let Ok(mb) = dict.get(b"MediaBox") {
                    if let Ok(arr) = mb.as_array() {
                        let v: Vec<f32> = arr.iter().filter_map(|o| o.as_float().ok()).collect();
                        if v.len() >= 4 {
                            info.push_str(&format!(" MediaBox=[{:.1} {:.1} {:.1} {:.1}]", v[0], v[1], v[2], v[3]));
                        }
                    }
                }
                eprintln!("  obj {}.{}: {}", id.0, id.1, info);
            } else if let Ok(arr) = obj.as_array() {
                eprintln!("  obj {}.{}: array[{}]", id.0, id.1, arr.len());
            } else {
                eprintln!("  obj {}.{}: {:?}", id.0, id.1, obj);
            }
        }
        return;
    }

    // --emf: export EMF
    if emf_mode {
        export_emf(&doc, pdf_path);
        return;
    }

    let pages = doc.get_pages();
    eprintln!("Pages: {}", pages.len());

    let mut page_bbox: HashMap<ObjectId, (f32, f32, f32, f32)> = HashMap::new();

    for (&num, &page_id) in &pages {
        eprintln!("--- Page {} (obj {}) ---", num, page_id.0);

        if let Some(obj) = doc.objects.get(&page_id) {
            if let Ok(dict) = obj.as_dict() {
                if let Ok(mb) = dict.get(b"MediaBox") {
                    if let Ok(arr) = mb.as_array() {
                        let v: Vec<f32> = arr.iter().filter_map(|o| o.as_float().ok()).collect();
                        if v.len() >= 4 {
                            eprintln!("  Original MediaBox: [{:.1} {:.1} {:.1} {:.1}]", v[0], v[1], v[2], v[3]);
                        }
                    }
                }
            }
        }

        let mut bbox: Option<(f64, f64, f64, f64)> = None;

        if let Some(bytes) = page_content_bytes(&doc, page_id) {
            eprintln!("  Content size: {} bytes", bytes.len());
            let resources = page_resources(&doc, page_id);
            bbox = process_content(&doc, &bytes, resources.as_ref(), [1.0, 0.0, 0.0, 1.0, 0.0, 0.0], 1, dump);
        } else {
            eprintln!("  No content stream found!");
        }

        if let Some(obj) = doc.objects.get(&page_id) {
            if let Ok(dict) = obj.as_dict() {
                if let Ok(trim) = dict.get(b"TrimBox") {
                    if let Ok(arr) = trim.as_array() {
                        if arr.len() >= 4 {
                            let tx1 = arr[0].as_float().unwrap_or(0.0) as f64;
                            let ty1 = arr[1].as_float().unwrap_or(0.0) as f64;
                            let tx2 = arr[2].as_float().unwrap_or(0.0) as f64;
                            let ty2 = arr[3].as_float().unwrap_or(0.0) as f64;
                            eprintln!("  TrimBox: [{:.1} {:.1} {:.1} {:.1}]", tx1, ty1, tx2, ty2);
                            bbox = Some(match bbox {
                                Some((x1, y1, x2, y2)) => (x1.min(tx1), y1.min(ty1), x2.max(tx2), y2.max(ty2)),
                                None => (tx1, ty1, tx2, ty2),
                            });
                        }
                    }
                }
            }
        }

        if let Some((x1, y1, x2, y2)) = bbox {
            eprintln!("  Final bbox: ({:.1}, {:.1}) \u{2192} ({:.1}, {:.1})", x1, y1, x2, y2);
            page_bbox.insert(
                page_id,
                (
                    (x1 as f32) - pad_pt,
                    (y1 as f32) - pad_pt,
                    (x2 as f32) + pad_pt,
                    (y2 as f32) + pad_pt,
                ),
            );
        } else {
            eprintln!("  WARNING: No bounding box found, page not cropped!");
        }
    }

    for (_, obj) in doc.objects.iter_mut() {
        if let Ok(dict) = obj.as_dict_mut() {
            dict.remove(b"OCProperties");
            dict.remove(b"PieceInfo");
        }
    }
    for (&num, &page_id) in &pages {
        if let Some(&(l, b, r, t)) = page_bbox.get(&page_id) {
            eprintln!("  Page {} new MediaBox: [{:.1} {:.1} {:.1} {:.1}]", num, l, b, r, t);
            if let Some(obj) = doc.objects.get_mut(&page_id) {
                if let Ok(dict) = obj.as_dict_mut() {
                    let rect = Object::Array(vec![
                        Object::Real(l),
                        Object::Real(b),
                        Object::Real(r),
                        Object::Real(t),
                    ]);
                    dict.set("MediaBox", rect.clone());
                    dict.set("CropBox", rect);
                }
            }
        }
    }

    let tmp = format!("{}.tmp", pdf_path);
    doc.save(&tmp).expect("Failed to save");
    fs::rename(&tmp, pdf_path).expect("Failed to replace");

    eprintln!("=== Done ===");
}

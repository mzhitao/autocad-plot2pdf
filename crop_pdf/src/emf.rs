fn pt2hu(pt: f64) -> i32 { (pt * 25.4 / 72.0 * 100.0) as i32 }

enum Rec {
    Raw(Vec<u8>),
}

pub struct Emf {
    recs: Vec<Rec>,
    nrec: u32,
    bx: [f64;4],
    pw: f64, ph: f64,
}

impl Emf {
    pub fn new(pw_pt: f64, ph_pt: f64) -> Self {
        Self {
            recs: Vec::new(),
            nrec: 0,
            bx: [f64::MAX, f64::MAX, f64::MIN, f64::MIN],
            pw: pw_pt, ph: ph_pt,
        }
    }

    fn yf(&self, y: f64) -> f64 { self.ph - y }

    fn track(&mut self, x: f64, y: f64) {
        self.bx = [self.bx[0].min(x),self.bx[1].min(y),self.bx[2].max(x),self.bx[3].max(y)];
    }

    fn push(&mut self, ty: u32, dat: &[u8]) {
        let sz = (8 + dat.len() + 3) / 4 * 4;
        let mut d = Vec::with_capacity(sz as usize);
        d.extend_from_slice(&ty.to_le_bytes());
        d.extend_from_slice(&(sz as u32).to_le_bytes());
        d.extend_from_slice(dat);
        d.resize(sz as usize, 0);
        self.recs.push(Rec::Raw(d));
        self.nrec += 1;
    }

    pub fn savedc(&mut self) { self.push(33, &[0u8;4]); }
    pub fn restoredc(&mut self) { self.push(34, &[0u8;4]); }
    pub fn beginpath(&mut self) { self.push(9, &[0u8;4]); }
    pub fn endpath(&mut self) { self.push(10, &[0u8;4]); }
    pub fn closefig(&mut self) { self.push(61, &[0u8;4]); }

    pub fn moveto(&mut self, x: f64, y: f64) {
        let y = self.yf(y);
        self.track(x, y);
        let mut d = Vec::with_capacity(16);
        d.extend_from_slice(&pt2hu(x).to_le_bytes());
        d.extend_from_slice(&pt2hu(y).to_le_bytes());
        d.extend_from_slice(&[0u8;4]);
        self.push(27, &d);
    }

    pub fn lineto(&mut self, x: f64, y: f64) {
        let y = self.yf(y);
        self.track(x, y);
        let mut d = Vec::with_capacity(12);
        d.extend_from_slice(&pt2hu(x).to_le_bytes());
        d.extend_from_slice(&pt2hu(y).to_le_bytes());
        self.push(2, &d);
    }

    pub fn curveto(&mut self, x1:f64,y1:f64,x2:f64,y2:f64,x3:f64,y3:f64) {
        let pts = [(x1,self.yf(y1)),(x2,self.yf(y2)),(x3,self.yf(y3))];
        for &(x,y) in &pts {
            self.track(x, y);
        }
        let mut d = Vec::with_capacity(36);
        for &(x,y) in &pts {
            d.extend_from_slice(&pt2hu(x).to_le_bytes());
            d.extend_from_slice(&pt2hu(y).to_le_bytes());
        }
        self.push(5, &d);
    }

    pub fn rect(&mut self, x:f64,y:f64,w:f64,h:f64) {
        let x2 = x + w; let y2 = y + h;
        let y = self.yf(y); let y2 = self.yf(y2);
        let xl = x.min(x2); let xr = x.max(x2);
        let yt = y.min(y2); let yb = y.max(y2);
        self.track(xl, yt);
        self.track(xr, yb);
        let mut d = Vec::with_capacity(16);
        d.extend_from_slice(&pt2hu(xl).to_le_bytes());
        d.extend_from_slice(&pt2hu(yt).to_le_bytes());
        d.extend_from_slice(&pt2hu(xr).to_le_bytes());
        d.extend_from_slice(&pt2hu(yb).to_le_bytes());
        self.push(43, &d); // EMR_RECTANGLE
    }

    pub fn stroke(&mut self) { self.push(64, &[0u8;8]); }
    pub fn fill(&mut self) { self.push(62, &[0u8;8]); }
    pub fn fillstroke(&mut self) { self.push(63, &[0u8;8]); }

    pub fn save(&self, path: &str) -> std::io::Result<()> {
        let mut buf = Vec::new();

        let (cx0, cy0, cx1, cy1) = (
            if self.bx[0].is_finite() { self.bx[0] } else { 0.0 },
            if self.bx[1].is_finite() { self.bx[1] } else { 0.0 },
            if self.bx[2].is_finite() { self.bx[2] } else { self.pw },
            if self.bx[3].is_finite() { self.bx[3] } else { self.ph },
        );
        let b = [
            pt2hu(cx0),
            pt2hu(self.yf(cy1)),  // EMF Y up → down
            pt2hu(cx1),
            pt2hu(self.yf(cy0)),
        ];
        let f = [
            pt2hu(cx0), pt2hu(cy0),
            pt2hu(cx1), pt2hu(cy1),
        ];

        let mut total: u32 = 128;
        for Rec::Raw(dat) in &self.recs {
            total += dat.len() as u32;
        }
        total += 20; // EMR_EOF

        // Write header
        let mut h = Vec::with_capacity(128);
        h.extend_from_slice(&1u32.to_le_bytes());     // Type
        h.extend_from_slice(&128u32.to_le_bytes());    // Size
        h.extend_from_slice(&b[0].to_le_bytes());      // Bounds.left
        h.extend_from_slice(&b[1].to_le_bytes());      // Bounds.top
        h.extend_from_slice(&b[2].to_le_bytes());      // Bounds.right
        h.extend_from_slice(&b[3].to_le_bytes());      // Bounds.bottom
        h.extend_from_slice(&f[0].to_le_bytes());      // Frame.left
        h.extend_from_slice(&f[1].to_le_bytes());      // Frame.top
        h.extend_from_slice(&f[2].to_le_bytes());      // Frame.right
        h.extend_from_slice(&f[3].to_le_bytes());      // Frame.bottom
        h.extend_from_slice(&0x464D4520u32.to_le_bytes()); // Signature " EMF"
        h.extend_from_slice(&0x00010000u32.to_le_bytes()); // Version
        h.extend_from_slice(&total.to_le_bytes());     // Size (file)
        h.extend_from_slice(&(self.nrec + 2).to_le_bytes()); // Records
        h.extend_from_slice(&1u16.to_le_bytes());      // Handles
        h.extend_from_slice(&0u16.to_le_bytes());      // Reserved
        h.extend_from_slice(&0u32.to_le_bytes());      // nDescription
        h.extend_from_slice(&0u32.to_le_bytes());      // offDescription
        h.extend_from_slice(&0u32.to_le_bytes());      // nPalEntries
        // szlDevice (pixels at 96 DPI)
        let dev_cx = (self.pw * 96.0 / 72.0) as i32;
        let dev_cy = (self.ph * 96.0 / 72.0) as i32;
        h.extend_from_slice(&dev_cx.to_le_bytes());
        h.extend_from_slice(&dev_cy.to_le_bytes());
        // szlMillimeters
        let mm_w = (self.pw * 25.4 / 72.0) as i32;
        let mm_h = (self.ph * 25.4 / 72.0) as i32;
        h.extend_from_slice(&mm_w.to_le_bytes());
        h.extend_from_slice(&mm_h.to_le_bytes());
        // cbPixelFormat / offPixelFormat / bOpenGL
        h.extend_from_slice(&0u32.to_le_bytes());
        h.extend_from_slice(&0u32.to_le_bytes());
        h.extend_from_slice(&0u32.to_le_bytes());
        h.resize(128, 0);

        buf.extend_from_slice(&h);

        for Rec::Raw(dat) in &self.recs {
            buf.extend_from_slice(dat);
        }

        // EMR_EOF
        buf.extend_from_slice(&14u32.to_le_bytes());   // Type
        buf.extend_from_slice(&20u32.to_le_bytes());   // Size
        buf.extend_from_slice(&b[0].to_le_bytes());    // Bounds
        buf.extend_from_slice(&b[1].to_le_bytes());
        buf.extend_from_slice(&b[2].to_le_bytes());
        buf.extend_from_slice(&b[3].to_le_bytes());

        std::fs::write(path, &buf)
    }
}

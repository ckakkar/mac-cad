//! DXF reader written from Autodesk's published DXF reference. It decodes the
//! drawing data MacCAD can represent and reports, by type, everything it omits.
//! DWG files reach it through LibreDWG's DWG-to-DXF conversion.
use crate::{
    curves::spline_point,
    geometry::{Point, Transform, EPS},
    model::{
        Attribute, BlockEntity, DimensionInfo, Document, Entity, EntityStyle, Header, Layer,
        LineTypeDef, PatternLine, Shape, TextFormat, TextStyle, Vertex, BY_BLOCK_COLOR,
        BY_BLOCK_LINE_TYPE, BY_BLOCK_LINE_WEIGHT,
    },
};
use std::collections::{BTreeMap, HashMap};
use std::f64::consts::TAU;
use std::path::Path;
use std::sync::Arc;

type Pair<'a> = (i32, &'a str);
/// A sequence parent (POLYLINE, INSERT) with its VERTEX/ATTRIB children.
type Sequence<'a> = (String, Vec<Pair<'a>>, Vec<(&'a str, Vec<Pair<'a>>)>);

/// Group-code pairs from ASCII DXF text, without copying values.
struct Pairs<'a> {
    lines: std::str::Split<'a, char>,
    line: usize,
    peeked: Option<Pair<'a>>,
}
impl<'a> Pairs<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            lines: text.split('\n'),
            line: 0,
            peeked: None,
        }
    }
    fn next(&mut self) -> Result<Option<Pair<'a>>, String> {
        if let Some(p) = self.peeked.take() {
            return Ok(Some(p));
        }
        let code = loop {
            let Some(raw) = self.lines.next() else {
                return Ok(None);
            };
            self.line += 1;
            let trimmed = raw.trim();
            if !trimmed.is_empty() {
                break trimmed;
            }
        };
        let code: i32 = code.parse().map_err(|_| {
            format!(
                "DXF line {}: expected a group code, found {code:?}",
                self.line
            )
        })?;
        let value = self.lines.next().ok_or("DXF ended inside a group pair")?;
        self.line += 1;
        Ok(Some((code, value.strip_suffix('\r').unwrap_or(value))))
    }
    /// The next 0-delimited record: its type and the pairs that follow it.
    fn record(&mut self) -> Result<Option<(&'a str, Vec<Pair<'a>>)>, String> {
        let kind = loop {
            match self.next()? {
                None => return Ok(None),
                Some((0, v)) => break v.trim(),
                Some(_) => continue,
            }
        };
        let mut pairs = Vec::new();
        while let Some(p) = self.next()? {
            if p.0 == 0 {
                self.peeked = Some(p);
                break;
            }
            pairs.push(p);
        }
        Ok(Some((kind, pairs)))
    }
}

/// MacCAD's spelling for built-in linetypes; drawing-defined names are kept.
fn line_type_name(n: &str) -> String {
    for builtin in ["Continuous", "Dashed", "Hidden", "Center", "Dotted"] {
        if n.eq_ignore_ascii_case(builtin) {
            return builtin.into();
        }
    }
    n.to_string()
}
/// "Standard" is the default text style and is stored as the empty name.
fn style_name(n: Option<&str>) -> String {
    let n = n.unwrap_or("").trim();
    if n.eq_ignore_ascii_case("Standard") {
        String::new()
    } else {
        n.to_string()
    }
}
fn num(v: &str) -> f64 {
    v.trim().parse().unwrap_or(0.0)
}
fn int(v: &str) -> i64 {
    let v = v.trim();
    v.parse::<i64>()
        .or_else(|_| v.parse::<f64>().map(|f| f as i64))
        .unwrap_or(0)
}
/// First value for a group code.
fn get<'a>(p: &[Pair<'a>], code: i32) -> Option<&'a str> {
    p.iter().find(|(c, _)| *c == code).map(|(_, v)| *v)
}
fn getf(p: &[Pair], code: i32, default: f64) -> f64 {
    get(p, code).map_or(default, num)
}
fn geti(p: &[Pair], code: i32, default: i64) -> i64 {
    get(p, code).map_or(default, int)
}
fn point(p: &[Pair], x: i32) -> Point {
    Point::new(getf(p, x, 0.0), getf(p, x + 10, 0.0))
}

/// AutoCAD Color Index to RGB, following the published ACI table structure.
pub fn aci(index: u8) -> [f32; 4] {
    let rgb = |r: f64, g: f64, b: f64| [r as f32 / 255.0, g as f32 / 255.0, b as f32 / 255.0, 1.0];
    match index {
        1 => rgb(255.0, 0.0, 0.0),
        2 => rgb(255.0, 255.0, 0.0),
        3 => rgb(0.0, 255.0, 0.0),
        4 => rgb(0.0, 255.0, 255.0),
        5 => rgb(0.0, 0.0, 255.0),
        6 => rgb(255.0, 0.0, 255.0),
        8 => rgb(128.0, 128.0, 128.0),
        9 => rgb(192.0, 192.0, 192.0),
        10..=249 => {
            let i = index as usize - 10;
            let hue = (i / 10) as f64 * 15.0;
            let value = [255.0, 204.0, 153.0, 127.0, 76.0][(i % 10) / 2];
            let saturation = if i.is_multiple_of(2) { 1.0 } else { 0.5 };
            let h = hue / 60.0;
            let x = 1.0 - (h % 2.0 - 1.0).abs();
            let (r, g, b) = match h as u32 {
                0 => (1.0, x, 0.0),
                1 => (x, 1.0, 0.0),
                2 => (0.0, 1.0, x),
                3 => (0.0, x, 1.0),
                4 => (x, 0.0, 1.0),
                _ => (1.0, 0.0, x),
            };
            let c = |v: f64| (value * (1.0 - saturation * (1.0 - v))).floor();
            rgb(c(r), c(g), c(b))
        }
        250 => rgb(51.0, 51.0, 51.0),
        251 => rgb(91.0, 91.0, 91.0),
        252 => rgb(132.0, 132.0, 132.0),
        253 => rgb(173.0, 173.0, 173.0),
        254 => rgb(214.0, 214.0, 214.0),
        _ => rgb(255.0, 255.0, 255.0),
    }
}
fn true_color(v: i64) -> [f32; 4] {
    let n = v as u32;
    [
        ((n >> 16) & 255) as f32 / 255.0,
        ((n >> 8) & 255) as f32 / 255.0,
        (n & 255) as f32 / 255.0,
        1.0,
    ]
}

/// Object coordinate system to drawing XY, by the arbitrary axis algorithm. True
/// 3D extrusions are projected onto the XY plane (a plan view).
fn ocs(p: &[Pair]) -> Transform {
    let n = (getf(p, 210, 0.0), getf(p, 220, 0.0), getf(p, 230, 1.0));
    let len = (n.0 * n.0 + n.1 * n.1 + n.2 * n.2).sqrt();
    if len < EPS || (n.0.abs() < 1e-12 && n.1.abs() < 1e-12 && n.2 > 0.0) {
        return Transform::IDENTITY;
    }
    let n = (n.0 / len, n.1 / len, n.2 / len);
    let cross = |a: (f64, f64, f64), b: (f64, f64, f64)| {
        (
            a.1 * b.2 - a.2 * b.1,
            a.2 * b.0 - a.0 * b.2,
            a.0 * b.1 - a.1 * b.0,
        )
    };
    let unit = |a: (f64, f64, f64)| {
        let l = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).sqrt().max(EPS);
        (a.0 / l, a.1 / l, a.2 / l)
    };
    let ax = if n.0.abs() < 1.0 / 64.0 && n.1.abs() < 1.0 / 64.0 {
        unit(cross((0.0, 1.0, 0.0), n))
    } else {
        unit(cross((0.0, 0.0, 1.0), n))
    };
    let ay = unit(cross(n, ax));
    Transform {
        a: ax.0,
        b: ax.1,
        c: ay.0,
        d: ay.1,
        tx: 0.0,
        ty: 0.0,
    }
}

/// TEXT/ATTRIB control codes and \U+XXXX escapes.
fn decode_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c == '%' && i + 2 < chars.len() && chars[i + 1] == '%' {
            let k = chars[i + 2].to_ascii_lowercase();
            i += 3;
            match k {
                'c' => out.push('Ø'),
                'd' => out.push('°'),
                'p' => out.push('±'),
                '%' => out.push('%'),
                'u' | 'o' | 'k' => {}
                d if d.is_ascii_digit() => {
                    let mut n = d.to_digit(10).unwrap();
                    while i < chars.len() && chars[i].is_ascii_digit() && n < 1000 {
                        n = n * 10 + chars[i].to_digit(10).unwrap();
                        i += 1;
                    }
                    out.extend(char::from_u32(n));
                }
                other => {
                    out.push_str("%%");
                    out.push(other);
                }
            }
            continue;
        }
        if c == '\\'
            && i + 6 < chars.len() + 1
            && chars.get(i + 1) == Some(&'U')
            && chars.get(i + 2) == Some(&'+')
        {
            let hex: String = chars[i + 3..(i + 7).min(chars.len())].iter().collect();
            if let Some(ch) = u32::from_str_radix(&hex, 16).ok().and_then(char::from_u32) {
                out.push(ch);
                i += 7;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }
    out
}
/// The first paragraph's first-line and left indents from an MTEXT `\p` code
/// such as `\pxi-3,l3,t4;`, in drawing units.
fn paragraph_indent(raw: &str) -> (f64, f64) {
    let Some(start) = raw.find("\\p").filter(|&i| !raw[..i].ends_with('\\')) else {
        return (0.0, 0.0);
    };
    let rest = &raw[start + 2..];
    let body = &rest[..rest.find(';').unwrap_or(rest.len())];
    let (mut first, mut left) = (0.0, 0.0);
    for token in body.split(',') {
        let token = token.trim_start_matches('x');
        if let Some(v) = token.strip_prefix('i') {
            first = v.parse().unwrap_or(0.0);
        } else if let Some(v) = token.strip_prefix('l') {
            left = v.parse().unwrap_or(0.0);
        }
    }
    (first, left)
}
/// MTEXT content without inline formatting codes; paragraphs become newlines.
pub fn plain_mtext(s: &str) -> String {
    let s = decode_text(s);
    let mut out = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '{' | '}' => {}
            '\\' => match chars.next() {
                Some('P') | Some('N') | Some('X') => out.push('\n'),
                Some(c @ ('\\' | '{' | '}')) => out.push(c),
                Some('~') => out.push('\u{a0}'),
                Some('L' | 'l' | 'O' | 'o' | 'K' | 'k') => {}
                Some('S') => {
                    // Stacked text a^b, a/b or a#b reads as a/b, set apart
                    // from a preceding whole number: 7\S1/4; is "7 1/4".
                    if out.ends_with(|c: char| c.is_ascii_digit()) {
                        out.push(' ');
                    }
                    while let Some(&c) = chars.peek() {
                        chars.next();
                        match c {
                            ';' => break,
                            '^' | '#' => out.push('/'),
                            _ => out.push(c),
                        }
                    }
                }
                Some(_) => {
                    while chars.peek().is_some_and(|c| *c != ';') {
                        chars.next();
                    }
                    chars.next();
                }
                None => {}
            },
            _ => out.push(c),
        }
    }
    out
}

#[derive(Default)]
struct Context {
    layers: Vec<Layer>,
    linetypes: BTreeMap<String, LineTypeDef>,
    text_styles: BTreeMap<String, TextStyle>,
    /// Arrow size per dimension style (DIMASZ × DIMSCALE).
    arrow: HashMap<String, f64>,
    header: Header,
    insunits: i64,
    measurement: i64,
    image_defs: HashMap<String, String>,
    ole: usize,
    skipped: BTreeMap<String, usize>,
    notes: Vec<String>,
}
impl Context {
    fn skip(&mut self, what: &str) {
        *self.skipped.entry(what.to_string()).or_default() += 1;
    }
}

/// Properties common to every entity.
struct Common {
    layer: String,
    style: EntityStyle,
    paper: bool,
    invisible: bool,
}
fn common(p: &[Pair]) -> Common {
    let mut style = EntityStyle::default();
    let mut color = None;
    for &(code, v) in p {
        match code {
            62 => {
                let c = int(v);
                if c == 0 {
                    style.by_block |= BY_BLOCK_COLOR;
                } else if (1..=255).contains(&c) {
                    color.get_or_insert(aci(c as u8));
                }
            }
            420 => color = Some(true_color(int(v))),
            6 => {
                let n = v.trim();
                if n.eq_ignore_ascii_case("ByBlock") {
                    style.by_block |= BY_BLOCK_LINE_TYPE;
                } else if !n.eq_ignore_ascii_case("ByLayer") && !n.is_empty() {
                    style.line_type = Some(line_type_name(n));
                }
            }
            370 => match int(v) {
                -2 => style.by_block |= BY_BLOCK_LINE_WEIGHT,
                -1 => {}
                -3 => style.line_weight = Some(0.25),
                w if (0..=211).contains(&w) => style.line_weight = Some(w as f32 / 100.0),
                _ => {}
            },
            48 => {
                let s = num(v);
                if s > EPS && (s - 1.0).abs() > 1e-12 {
                    style.line_type_scale = Some(s);
                }
            }
            _ => {}
        }
    }
    if style.by_block & BY_BLOCK_COLOR == 0 {
        style.color = color;
    }
    Common {
        layer: get(p, 8)
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "0".into()),
        style,
        paper: geti(p, 67, 0) == 1,
        invisible: geti(p, 60, 0) == 1,
    }
}

/// Builds a polyline loop from hatch boundary edges.
struct Edges {
    vertices: Vec<Vertex>,
}
impl Edges {
    fn start(&mut self, p: Point) {
        if self
            .vertices
            .last()
            .is_none_or(|v| v.point.distance(p) > 1e-9)
        {
            self.vertices.push(Vertex::new(p, 0.0));
        }
    }
    fn to(&mut self, p: Point) {
        self.vertices.push(Vertex::new(p, 0.0));
    }
}

/// Reads one hatch's boundary loops and pattern lines.
fn hatch(p: &[Pair], ctx: &mut Context) -> Option<Shape> {
    let mut i = p.iter().position(|(c, _)| *c == 91)?;
    let loops_count = int(p[i].1).max(0) as usize;
    i += 1;
    let at = |i: usize| p.get(i).copied().unwrap_or((-1, ""));
    let mut loops = Vec::new();
    for _ in 0..loops_count.min(100_000) {
        while i < p.len() && at(i).0 != 92 {
            i += 1;
        }
        if i >= p.len() {
            break;
        }
        let flags = int(at(i).1);
        i += 1;
        let mut edges = Edges {
            vertices: Vec::new(),
        };
        if flags & 2 != 0 {
            // Polyline boundary: 72 has-bulge, 73 closed, 93 count, then 10/20(/42).
            let mut count = 0;
            while i < p.len() && at(i).0 != 93 {
                i += 1;
            }
            if i < p.len() {
                count = int(at(i).1).max(0) as usize;
                i += 1;
            }
            for _ in 0..count {
                while i < p.len() && at(i).0 != 10 {
                    i += 1;
                }
                if i + 1 >= p.len() {
                    break;
                }
                let v = Point::new(num(at(i).1), num(at(i + 1).1));
                i += 2;
                let mut vertex = Vertex::new(v, 0.0);
                if at(i).0 == 42 {
                    vertex.bulge = num(at(i).1);
                    i += 1;
                }
                edges.vertices.push(vertex);
            }
        } else {
            while i < p.len() && at(i).0 != 93 {
                i += 1;
            }
            let count = if i < p.len() {
                int(at(i).1).max(0) as usize
            } else {
                0
            };
            i += 1;
            for _ in 0..count.min(100_000) {
                while i < p.len() && at(i).0 != 72 {
                    i += 1;
                }
                if i >= p.len() {
                    break;
                }
                let kind = int(at(i).1);
                i += 1;
                // Gather this edge's pairs up to the next edge type or loop marker.
                let begin = i;
                while i < p.len() && !matches!(at(i).0, 72 | 92 | 97 | 75) {
                    i += 1;
                }
                let e = &p[begin..i];
                match kind {
                    1 => {
                        edges.start(point(e, 10));
                        edges.to(point(e, 11));
                    }
                    2 => {
                        let c = point(e, 10);
                        let r = getf(e, 40, 0.0);
                        let ccw = geti(e, 73, 1) != 0;
                        let (s, en) =
                            (getf(e, 50, 0.0).to_radians(), getf(e, 51, 0.0).to_radians());
                        let (s, sweep) = if ccw {
                            let mut w = (en - s).rem_euclid(TAU);
                            if w < 1e-12 {
                                w = TAU;
                            }
                            (s, w)
                        } else {
                            let (s, en) = (-s, -en);
                            let mut w = (s - en).rem_euclid(TAU);
                            if w < 1e-12 {
                                w = TAU;
                            }
                            (s, -w)
                        };
                        if sweep.abs() >= TAU - 1e-9 {
                            // A full circle: two half-arc bulges.
                            let a = c + Point::new(s.cos(), s.sin()) * r;
                            let b = c - Point::new(s.cos(), s.sin()) * r;
                            let bulge = if ccw { 1.0 } else { -1.0 };
                            edges.vertices.push(Vertex::new(a, bulge));
                            edges.vertices.push(Vertex::new(b, bulge));
                            continue;
                        }
                        edges.start(c + Point::new(s.cos(), s.sin()) * r);
                        if let Some(last) = edges.vertices.last_mut() {
                            last.bulge = (sweep / 4.0).tan();
                        }
                        let e_ang = s + sweep;
                        edges.to(c + Point::new(e_ang.cos(), e_ang.sin()) * r);
                    }
                    3 => {
                        let c = point(e, 10);
                        let major = point(e, 11);
                        let ratio = getf(e, 40, 1.0);
                        let ccw = geti(e, 73, 1) != 0;
                        let (mut s, mut en) =
                            (getf(e, 50, 0.0).to_radians(), getf(e, 51, 0.0).to_radians());
                        if !ccw {
                            (s, en) = (-s, -en);
                        }
                        let mut sweep = if ccw {
                            (en - s).rem_euclid(TAU)
                        } else {
                            -(s - en).rem_euclid(TAU)
                        };
                        if sweep.abs() < 1e-12 {
                            sweep = TAU;
                        }
                        let n = 64;
                        let minor = Point::new(-major.y, major.x) * ratio;
                        for k in 0..=n {
                            let t = s + sweep * k as f64 / n as f64;
                            let q = c + major * t.cos() + minor * t.sin();
                            if k == 0 {
                                edges.start(q)
                            } else {
                                edges.to(q)
                            }
                        }
                    }
                    4 => {
                        let degree = geti(e, 94, 3).clamp(1, 7) as usize;
                        let knots: Vec<f64> = e
                            .iter()
                            .filter(|(c, _)| *c == 40)
                            .map(|(_, v)| num(v))
                            .collect();
                        let mut cps = Vec::new();
                        let mut weights = Vec::new();
                        let mut fits = Vec::new();
                        for (k, (c, v)) in e.iter().enumerate() {
                            match c {
                                10 => cps.push(Point::new(
                                    num(v),
                                    e.get(k + 1).map_or(0.0, |x| num(x.1)),
                                )),
                                42 => weights.push(num(v)),
                                11 => fits.push(Point::new(
                                    num(v),
                                    e.get(k + 1).map_or(0.0, |x| num(x.1)),
                                )),
                                _ => {}
                            }
                        }
                        if weights.len() != cps.len() {
                            weights = vec![1.0; cps.len()];
                        }
                        if cps.len() > degree && knots.len() == cps.len() + degree + 1 {
                            let (lo, hi) = (knots[degree], knots[cps.len()]);
                            for k in 0..=64 {
                                let q = spline_point(
                                    degree,
                                    &cps,
                                    &knots,
                                    &weights,
                                    lo + (hi - lo) * k as f64 / 64.0,
                                );
                                if k == 0 {
                                    edges.start(q)
                                } else {
                                    edges.to(q)
                                }
                            }
                        } else if !fits.is_empty() {
                            for (k, q) in fits.into_iter().enumerate() {
                                if k == 0 {
                                    edges.start(q)
                                } else {
                                    edges.to(q)
                                }
                            }
                        }
                    }
                    _ => ctx.skip("hatch boundary edge"),
                }
            }
        }
        // Closed loops repeat their first point; drop the duplicate.
        if edges.vertices.len() > 2
            && edges.vertices[0]
                .point
                .distance(edges.vertices.last().unwrap().point)
                < 1e-9
        {
            edges.vertices.pop();
        }
        if edges.vertices.len() >= 2 {
            loops.push(edges.vertices);
        }
    }
    if loops.is_empty() {
        return None;
    }
    let solid = geti(p, 70, 0) & 1 != 0 || get(p, 450).is_some_and(|v| int(v) == 1);
    // Pattern line definitions follow code 78 (count) as 53/43/44/45/46/79/49 groups.
    let mut lines = Vec::new();
    if let Some(start) = p.iter().position(|(c, _)| *c == 78) {
        let mut k = start + 1;
        while k < p.len() {
            if p[k].0 != 53 {
                if matches!(p[k].0, 47 | 98 | 450 | 1001) {
                    break;
                }
                k += 1;
                continue;
            }
            let angle = num(p[k].1).to_radians();
            let mut origin = Point::default();
            let mut offset = Point::default();
            let mut dashes = Vec::new();
            k += 1;
            while k < p.len() && !matches!(p[k].0, 53 | 47 | 98 | 450 | 1001) {
                match p[k].0 {
                    43 => origin.x = num(p[k].1),
                    44 => origin.y = num(p[k].1),
                    45 => offset.x = num(p[k].1),
                    46 => offset.y = num(p[k].1),
                    49 => dashes.push(num(p[k].1)),
                    _ => {}
                }
                k += 1;
            }
            lines.push(PatternLine {
                angle,
                origin,
                offset,
                dashes,
            });
        }
    }
    Some(Shape::Region {
        loops,
        solid,
        pattern: get(p, 2).unwrap_or("").trim().to_string(),
        lines,
    })
}

fn text_format(p: &[Pair], halign_code: i32, valign_code: i32) -> TextFormat {
    let halign = geti(p, halign_code, 0).clamp(0, 5) as u8;
    let valign = geti(p, valign_code, 0).clamp(0, 3) as u8;
    TextFormat {
        style: style_name(get(p, 7)),
        width_factor: Some(getf(p, 41, 1.0)).filter(|w| *w > EPS).unwrap_or(1.0),
        oblique: getf(p, 51, 0.0).to_radians(),
        halign,
        valign,
        align: (halign != 0 || valign != 0)
            .then(|| point(p, 11))
            .filter(|_| get(p, 11).is_some()),
        ..TextFormat::default()
    }
}

/// One record (and any sequence children) to shapes in drawing coordinates.
fn entity(
    kind: &str,
    p: &[Pair],
    children: &[(&str, Vec<Pair>)],
    ctx: &mut Context,
    in_block: bool,
) -> Vec<Shape> {
    let t = ocs(p);
    let one = |s: Shape| vec![s];
    match kind {
        "LINE" => {
            let (a, b) = (point(p, 10), point(p, 11));
            // AutoCAD draws zero-length lines as dots.
            one(if a.distance(b) <= EPS {
                Shape::Point { at: a }
            } else {
                Shape::Line { a, b }
            })
        }
        "POINT" => one(Shape::Point { at: point(p, 10) }),
        "CIRCLE" => one(Shape::Circle {
            center: point(p, 10),
            radius: getf(p, 40, 0.0),
        }
        .transformed(t)),
        "ARC" => {
            let s = getf(p, 50, 0.0);
            let mut sweep = (getf(p, 51, 360.0) - s).rem_euclid(360.0);
            if sweep < 1e-12 {
                sweep = 360.0;
            }
            one(Shape::Arc {
                center: point(p, 10),
                radius: getf(p, 40, 0.0),
                start: s.to_radians(),
                sweep: sweep.to_radians(),
            }
            .transformed(t))
        }
        "ELLIPSE" => {
            let (mut s, mut e) = (getf(p, 41, 0.0), getf(p, 42, TAU));
            if getf(p, 230, 1.0) < 0.0 {
                (s, e) = (-e, -s);
            }
            let mut sweep = (e - s).rem_euclid(TAU);
            if sweep < 1e-9 {
                sweep = TAU;
            }
            one(Shape::Ellipse {
                center: point(p, 10),
                major: point(p, 11),
                ratio: getf(p, 40, 1.0).min(1.0),
                start: s,
                sweep,
            })
        }
        "LWPOLYLINE" => {
            let constant = getf(p, 43, 0.0);
            let mut vertices: Vec<Vertex> = Vec::new();
            let mut k = 0;
            while k < p.len() {
                match p[k].0 {
                    10 => {
                        let y = p.get(k + 1).filter(|q| q.0 == 20).map_or(0.0, |q| num(q.1));
                        let mut v = Vertex::new(Point::new(num(p[k].1), y), 0.0);
                        v.start_width = constant;
                        v.end_width = constant;
                        vertices.push(v);
                    }
                    40 if !vertices.is_empty() => {
                        vertices.last_mut().unwrap().start_width = num(p[k].1)
                    }
                    41 if !vertices.is_empty() => {
                        vertices.last_mut().unwrap().end_width = num(p[k].1)
                    }
                    42 if !vertices.is_empty() => vertices.last_mut().unwrap().bulge = num(p[k].1),
                    _ => {}
                }
                k += 1;
            }
            if vertices.len() < 2 {
                return Vec::new();
            }
            one(Shape::Polyline {
                vertices,
                closed: geti(p, 70, 0) & 1 != 0,
            }
            .transformed(t))
        }
        "POLYLINE" => {
            let flags = geti(p, 70, 0);
            if flags & (16 | 64) != 0 {
                ctx.skip("polygon/polyface mesh");
                return Vec::new();
            }
            let (sw, ew) = (getf(p, 40, 0.0), getf(p, 41, 0.0));
            let three_d = flags & 8 != 0;
            let vertices: Vec<Vertex> = children
                .iter()
                .filter(|(k, vp)| *k == "VERTEX" && geti(vp, 70, 0) & 16 == 0)
                .map(|(_, vp)| Vertex {
                    point: point(vp, 10),
                    bulge: if three_d { 0.0 } else { getf(vp, 42, 0.0) },
                    start_width: getf(vp, 40, sw),
                    end_width: getf(vp, 41, ew),
                })
                .collect();
            if vertices.len() < 2 {
                return Vec::new();
            }
            let shape = Shape::Polyline {
                vertices,
                closed: flags & 1 != 0,
            };
            one(if three_d { shape } else { shape.transformed(t) })
        }
        "SPLINE" => {
            let degree = geti(p, 71, 3).clamp(1, 7) as usize;
            let knots: Vec<f64> = p
                .iter()
                .filter(|(c, _)| *c == 40)
                .map(|(_, v)| num(v))
                .collect();
            let mut cps = Vec::new();
            let mut fits = Vec::new();
            for (k, (c, v)) in p.iter().enumerate() {
                let y = || p.get(k + 1).map_or(0.0, |q| num(q.1));
                match c {
                    10 => cps.push(Point::new(num(v), y())),
                    11 => fits.push(Point::new(num(v), y())),
                    _ => {}
                }
            }
            let mut weights: Vec<f64> = p
                .iter()
                .filter(|(c, _)| *c == 41)
                .map(|(_, v)| num(v))
                .collect();
            if weights.len() != cps.len() {
                weights = vec![1.0; cps.len()];
            }
            if cps.len() > degree && knots.len() == cps.len() + degree + 1 {
                one(Shape::Spline {
                    degree,
                    control_points: cps,
                    knots,
                    weights,
                    closed: geti(p, 70, 0) & 1 != 0,
                })
            } else if fits.len() >= 2 {
                one(Shape::Polyline {
                    vertices: fits.into_iter().map(|q| Vertex::new(q, 0.0)).collect(),
                    closed: false,
                })
            } else {
                ctx.skip("SPLINE without control data");
                Vec::new()
            }
        }
        "TEXT" | "ATTDEF" => {
            let flags = geti(p, 70, 0);
            let value = if kind == "ATTDEF" {
                // Definitions show their tag outside blocks; constants show their value.
                if in_block && flags & 2 == 0 {
                    return Vec::new();
                }
                if in_block {
                    get(p, 1)
                } else {
                    get(p, 2)
                }
            } else {
                get(p, 1)
            };
            let text = decode_text(value.unwrap_or(""));
            if text.trim().is_empty() || flags & 1 != 0 && kind == "ATTDEF" && in_block {
                return Vec::new();
            }
            let height = getf(p, 40, 1.0);
            if height <= EPS {
                return Vec::new();
            }
            let format = text_format(p, 72, if kind == "ATTDEF" { 74 } else { 73 });
            one(Shape::Text {
                at: point(p, 10),
                text,
                height,
                rotation: getf(p, 50, 0.0).to_radians(),
                format,
            }
            .transformed(t))
        }
        "MTEXT" => {
            let mut raw = String::new();
            for (c, v) in p {
                if *c == 3 {
                    raw.push_str(v);
                }
            }
            raw.push_str(get(p, 1).unwrap_or(""));
            let text = plain_mtext(&raw);
            let height = getf(p, 40, 1.0);
            if text.trim().is_empty() || height <= EPS {
                return Vec::new();
            }
            let rotation = if get(p, 11).is_some() {
                let d = point(p, 11);
                d.y.atan2(d.x)
            } else {
                getf(p, 50, 0.0)
            };
            let mut format = TextFormat {
                style: style_name(get(p, 7)),
                attachment: geti(p, 71, 1).clamp(1, 9) as u8,
                wrap: getf(p, 41, 0.0).max(0.0),
                line_spacing: Some(getf(p, 44, 1.0)).filter(|v| *v > EPS).unwrap_or(1.0),
                ..TextFormat::default()
            };
            // A paragraph indent moves the text inside its column. MacCAD keeps
            // one column, so the indent becomes part of the insertion point.
            let mut at = point(p, 10);
            let (first, left) = paragraph_indent(&raw);
            let indent = if text.contains('\n') {
                left
            } else {
                left + first
            };
            let column = (format.attachment - 1) % 3;
            if indent.is_finite() && indent.abs() > EPS && (column == 0 || format.wrap > 0.0) {
                let shift = indent * (1.0 - column as f64 / 2.0);
                at = at + Point::new(rotation.cos(), rotation.sin()) * shift;
                if format.wrap > 0.0 {
                    format.wrap = (format.wrap - indent).max(height);
                }
            }
            one(Shape::Text {
                at,
                text,
                height,
                rotation,
                format,
            })
        }
        "INSERT" | "ACAD_TABLE" => {
            let block = get(p, 2).unwrap_or("").trim().to_string();
            if block.is_empty() {
                return Vec::new();
            }
            let sx = getf(p, 41, 1.0);
            let sy = getf(p, 42, 1.0);
            let rotation = getf(p, 50, 0.0).to_radians();
            let attributes: Vec<Attribute> = children
                .iter()
                .filter(|(k, _)| *k == "ATTRIB")
                .filter_map(|(_, ap)| {
                    let text = decode_text(get(ap, 1).unwrap_or(""));
                    let height = getf(ap, 40, 1.0);
                    (height > EPS).then(|| {
                        let a = Attribute {
                            tag: get(ap, 2).unwrap_or("").trim().to_string(),
                            text,
                            at: point(ap, 10),
                            height,
                            rotation: getf(ap, 50, 0.0).to_radians(),
                            format: text_format(ap, 72, 74),
                            invisible: geti(ap, 70, 0) & 1 != 0,
                        };
                        // Attributes have their own coordinate system.
                        let at = ocs(ap);
                        let Shape::Text {
                            at: pos,
                            height,
                            rotation,
                            format,
                            ..
                        } = Shape::Text {
                            at: a.at,
                            text: String::new(),
                            height: a.height,
                            rotation: a.rotation,
                            format: a.format.clone(),
                        }
                        .transformed(at)
                        else {
                            unreachable!()
                        };
                        Attribute {
                            at: pos,
                            height,
                            rotation,
                            format,
                            ..a
                        }
                    })
                })
                .collect();
            let (cols, rows) = (geti(p, 70, 1).max(1), geti(p, 71, 1).max(1));
            let (dx, dy) = (getf(p, 44, 0.0), getf(p, 45, 0.0));
            let base = point(p, 10);
            let mut out = Vec::new();
            for r in 0..rows.min(1000) {
                for c in 0..cols.min(1000) {
                    let offset = Transform::rotation(Point::default(), rotation, 1.0)
                        .apply(Point::new(c as f64 * dx, r as f64 * dy));
                    out.push(
                        Shape::Insert {
                            block: block.clone(),
                            at: base + offset,
                            scale: if sx.abs() > EPS { sx } else { 1.0 },
                            rotation,
                            y_scale: ((sy - sx).abs() > 1e-12 && sy.abs() > EPS).then_some(sy),
                            attributes: if r == 0 && c == 0 {
                                attributes.clone()
                            } else {
                                Vec::new()
                            },
                            dimension: None,
                        }
                        .transformed(t),
                    );
                }
            }
            out
        }
        "DIMENSION" | "ARC_DIMENSION" | "LARGE_RADIAL_DIMENSION" => {
            let block = get(p, 2).unwrap_or("").trim().to_string();
            let kinds = [
                "rotated",
                "aligned",
                "angular",
                "diameter",
                "radius",
                "angular3p",
                "ordinate",
            ];
            let kind_index = (geti(p, 70, 0) & 7) as usize;
            let info = DimensionInfo {
                kind: if kind == "DIMENSION" {
                    kinds.get(kind_index).copied().unwrap_or("rotated").into()
                } else {
                    kind.to_ascii_lowercase()
                },
                measurement: getf(p, 42, 0.0),
                text: decode_text(get(p, 1).unwrap_or("")),
                style: get(p, 3).unwrap_or("").trim().to_string(),
            };
            if !block.is_empty() {
                let mut s = Shape::insert(block, Point::default(), 1.0, 0.0);
                if let Shape::Insert { dimension, .. } = &mut s {
                    *dimension = Some(info);
                }
                return one(s.transformed(t));
            }
            ctx.skip("DIMENSION without graphics block");
            Vec::new()
        }
        "LEADER" => {
            let points: Vec<Point> = p
                .iter()
                .enumerate()
                .filter(|(_, (c, _))| *c == 10)
                .map(|(k, (_, v))| Point::new(num(v), p.get(k + 1).map_or(0.0, |q| num(q.1))))
                .collect();
            if points.len() < 2 || points[0].distance(points[1]) < EPS {
                return Vec::new();
            }
            let style = get(p, 3).unwrap_or("").trim();
            let mut arrow = ctx.arrow.get(style).copied().unwrap_or(0.0);
            // Per-object dimension variable overrides arrive in DSTYLE extended data.
            let mut k = 0;
            let (mut asz, mut scale) = (None, None);
            while k + 1 < p.len() {
                if p[k].0 == 1070 && p[k + 1].0 == 1040 {
                    match int(p[k].1) {
                        41 => asz = Some(num(p[k + 1].1)),
                        40 => scale = Some(num(p[k + 1].1)),
                        _ => {}
                    }
                }
                k += 1;
            }
            if let Some(a) = asz {
                arrow = a * scale.filter(|s| *s > EPS).unwrap_or(1.0);
            }
            if arrow <= EPS {
                arrow = getf(p, 40, 0.0).max(points[0].distance(points[1]) * 0.1);
            }
            if geti(p, 71, 1) == 0 {
                return one(Shape::Polyline {
                    vertices: points.into_iter().map(|q| Vertex::new(q, 0.0)).collect(),
                    closed: false,
                });
            }
            one(Shape::Leader {
                points,
                text: String::new(),
                height: arrow,
            })
        }
        "HATCH" => match hatch(p, ctx) {
            Some(s) => one(s.transformed(t)),
            None => {
                ctx.skip("HATCH without usable boundary");
                Vec::new()
            }
        },
        "SOLID" | "TRACE" => {
            let (a, b, c, d) = (point(p, 10), point(p, 11), point(p, 12), point(p, 13));
            let points = if c.distance(d) < EPS {
                vec![a, b, c]
            } else {
                vec![a, b, d, c]
            };
            one(Shape::Solid { points }.transformed(t))
        }
        "3DFACE" => {
            let flags = geti(p, 70, 0);
            let c = [point(p, 10), point(p, 11), point(p, 12), point(p, 13)];
            let n = if c[2].distance(c[3]) < EPS { 3 } else { 4 };
            (0..n)
                .filter(|i| flags & (1 << i) == 0)
                .map(|i| Shape::Line {
                    a: c[i],
                    b: c[(i + 1) % n],
                })
                .filter(|s| s.validate().is_ok())
                .collect()
        }
        "IMAGE" | "WIPEOUT" => {
            if kind == "WIPEOUT" {
                ctx.skip("WIPEOUT mask");
                return Vec::new();
            }
            let (w, h) = (getf(p, 13, 1.0), getf(p, 23, 1.0));
            let path = get(p, 340)
                .map(|h| format!("#{}", h.trim()))
                .unwrap_or_default();
            one(Shape::Image {
                at: point(p, 10),
                u: point(p, 11) * w,
                v: point(p, 12) * h,
                path,
            })
        }
        "OLE2FRAME" | "OLEFRAME" => {
            let (a, b) = (point(p, 10), point(p, 11));
            ctx.ole += 1;
            one(Shape::Image {
                at: Point::new(a.x, b.y),
                u: Point::new(b.x - a.x, 0.0),
                v: Point::new(0.0, a.y - b.y),
                path: "OLE object".into(),
            })
        }
        "XLINE" | "RAY" => one(Shape::XLine {
            at: point(p, 10),
            direction: point(p, 11),
            ray: kind == "RAY",
        }),
        "VERTEX" | "SEQEND" | "ATTRIB" | "VIEWPORT" => Vec::new(),
        other => {
            ctx.skip(other);
            Vec::new()
        }
    }
}

/// Reads DXF (from a file or LibreDWG's DWG conversion) into a native document.
pub fn read(path: &Path) -> Result<(Document, Vec<String>), String> {
    let len = std::fs::metadata(path).map_err(|e| e.to_string())?.len();
    if len > 4 * 1024 * 1024 * 1024 {
        return Err("Drawing exceeds the 4 GiB import limit".into());
    }
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    if bytes.starts_with(b"AutoCAD Binary DXF") {
        return Err("Binary DXF is not supported yet; save the drawing as ASCII DXF or DWG".into());
    }
    // DXF before R2007 uses the drawing code page; Latin-1 keeps every byte.
    let text = match String::from_utf8(bytes) {
        Ok(s) => s,
        Err(e) => e.into_bytes().into_iter().map(char::from).collect(),
    };
    parse(&text)
}

pub fn parse(text: &str) -> Result<(Document, Vec<String>), String> {
    let mut pairs = Pairs::new(text);
    let mut ctx = Context::default();
    let mut doc = Document::default();
    let mut blocks: BTreeMap<String, Vec<BlockEntity>> = BTreeMap::new();
    let mut xrefs = Vec::new();
    let mut paper = 0usize;
    let mut top: Vec<(Common, Shape)> = Vec::new();
    // Sequence parents (POLYLINE, INSERT with attributes) wait for SEQEND.
    let mut pending: Option<Sequence> = None;
    let mut block: Option<(String, Point, i64, Vec<BlockEntity>)> = None;
    let mut section = String::new();
    let mut ended = false;

    let emit = |kind: &str,
                p: Vec<Pair>,
                children: Vec<(&str, Vec<Pair>)>,
                ctx: &mut Context,
                block: &mut Option<(String, Point, i64, Vec<BlockEntity>)>,
                top: &mut Vec<(Common, Shape)>,
                paper: &mut usize| {
        let c = common(&p);
        if c.invisible {
            return;
        }
        let in_block = block.is_some();
        if !in_block && c.paper {
            *paper += 1;
            return;
        }
        for shape in entity(kind, &p, &children, ctx, in_block) {
            if shape.validate().is_err() {
                ctx.skip(&format!("{kind} with zero size"));
                continue;
            }
            match block {
                Some((_, _, _, entities)) => entities.push(BlockEntity {
                    layer: (c.layer != "0").then(|| c.layer.clone()),
                    style: c.style.clone(),
                    shape,
                }),
                None => top.push((
                    Common {
                        layer: c.layer.clone(),
                        style: c.style.clone(),
                        paper: false,
                        invisible: false,
                    },
                    shape,
                )),
            }
        }
    };

    while let Some((kind, p)) = pairs.record()? {
        match kind {
            "EOF" => {
                ended = true;
                break;
            }
            "SECTION" => {
                section = get(&p, 2).unwrap_or("").trim().to_string();
                if section == "HEADER" {
                    read_header(&p, &mut ctx);
                } else if section == "THUMBNAILIMAGE" {
                    ctx.notes.push("Embedded DXF preview thumbnail omitted; drawing geometry is imported separately.".into());
                }
                continue;
            }
            "ENDSEC" => {
                section.clear();
                continue;
            }
            _ => {}
        }
        match section.as_str() {
            "TABLES" => read_table_entry(kind, &p, &mut ctx),
            "OBJECTS" => {
                if kind == "IMAGEDEF" {
                    if let (Some(h), Some(f)) = (get(&p, 5), get(&p, 1)) {
                        ctx.image_defs.insert(h.trim().to_string(), f.to_string());
                    }
                }
            }
            "BLOCKS" | "ENTITIES" => {
                // Finish a pending sequence when its children end.
                if let Some((pk, pp, mut children)) = pending.take() {
                    if matches!(kind, "VERTEX" | "ATTRIB") {
                        children.push((kind, p));
                        pending = Some((pk, pp, children));
                        continue;
                    }
                    emit(
                        &pk, pp, children, &mut ctx, &mut block, &mut top, &mut paper,
                    );
                    if kind == "SEQEND" {
                        continue;
                    }
                }
                match kind {
                    "BLOCK" => {
                        let name = get(&p, 2).unwrap_or("").trim().to_string();
                        let flags = geti(&p, 70, 0);
                        if flags & 4 != 0 || get(&p, 1).is_some_and(|f| !f.trim().is_empty()) {
                            xrefs.push(name.clone());
                        }
                        block = Some((name, point(&p, 10), flags, Vec::new()));
                    }
                    "ENDBLK" => {
                        if let Some((name, base, _, entities)) = block.take() {
                            let lower = name.to_ascii_lowercase();
                            if !name.is_empty()
                                && !lower.starts_with("*model_space")
                                && !lower.starts_with("*paper_space")
                            {
                                let shift = Transform::translation(base * -1.0);
                                let entities = if base.length() > 0.0 {
                                    entities
                                        .into_iter()
                                        .map(|e| BlockEntity {
                                            shape: e.shape.transformed(shift),
                                            ..e
                                        })
                                        .collect()
                                } else {
                                    entities
                                };
                                blocks.insert(name, entities);
                            }
                        }
                    }
                    "POLYLINE" => pending = Some((kind.to_string(), p, Vec::new())),
                    "INSERT" if geti(&p, 66, 0) == 1 => {
                        pending = Some((kind.to_string(), p, Vec::new()))
                    }
                    "SEQEND" => {}
                    _ => emit(
                        kind,
                        p,
                        Vec::new(),
                        &mut ctx,
                        &mut block,
                        &mut top,
                        &mut paper,
                    ),
                }
            }
            _ => {}
        }
    }
    if !ended || !section.is_empty() {
        return Err(
            "The DXF file is truncated (it ends before its EOF marker); no drawing was opened."
                .into(),
        );
    }
    if let Some((pk, pp, children)) = pending.take() {
        emit(
            &pk, pp, children, &mut ctx, &mut block, &mut top, &mut paper,
        );
    }

    // Tables and drawing settings.
    let mut warnings = Vec::new();
    doc.units = match ctx.insunits {
        1 => "in",
        2 => "ft",
        4 => "mm",
        5 => "cm",
        6 => "m",
        _ => {
            if ctx.insunits != 0 {
                warnings.push(format!(
                    "Drawing units code {} is shown as {}; verify UNITS before plotting.",
                    ctx.insunits,
                    if ctx.measurement == 0 {
                        "inches"
                    } else {
                        "millimeters"
                    }
                ));
            }
            if ctx.measurement == 0 {
                "in"
            } else {
                "mm"
            }
        }
    }
    .into();
    doc.header = ctx.header.clone();
    doc.linetypes = std::mem::take(&mut ctx.linetypes);
    doc.text_styles = std::mem::take(&mut ctx.text_styles);
    for l in std::mem::take(&mut ctx.layers) {
        if l.name == "0" {
            doc.layers[0] = l;
        } else if doc.layer(&l.name).is_none() {
            doc.layers.push(l);
        }
    }
    let ensure_layer = |doc: &mut Document, name: &str| {
        if doc.layer(name).is_none() {
            doc.layers.push(Layer::new(name, aci(7)));
        }
    };
    for entities in blocks.values_mut() {
        for e in entities.iter_mut() {
            if let Some(l) = &e.layer {
                ensure_layer(&mut doc, l);
            }
            resolve_image(&mut e.shape, &ctx.image_defs);
        }
    }
    // References to missing blocks (including external references) are omitted.
    let known: std::collections::HashSet<String> = blocks.keys().cloned().collect();
    let mut missing = 0usize;
    for entities in blocks.values_mut() {
        entities.retain(|e| match &e.shape {
            Shape::Insert { block, .. } if !known.contains(block) => {
                missing += 1;
                false
            }
            _ => true,
        });
    }
    let mut next = 1u64;
    for (c, mut shape) in top {
        if let Shape::Insert { block, .. } = &shape {
            if !known.contains(block) {
                missing += 1;
                continue;
            }
        }
        resolve_image(&mut shape, &ctx.image_defs);
        ensure_layer(&mut doc, &c.layer);
        doc.entities.insert(
            next,
            Entity {
                id: next,
                layer: c.layer,
                style: c.style,
                shape,
            },
        );
        next += 1;
    }
    doc.next_id = next;
    doc.blocks = Arc::new(blocks);
    doc.current_layer = "0".into();

    if paper > 0 {
        warnings.push(format!(
            "{paper} paper-space (layout) objects are not shown; MacCAD shows model space."
        ));
    }
    if !xrefs.is_empty() {
        warnings.push(format!(
            "External references are not loaded: {}.",
            xrefs.join(", ")
        ));
    }
    if missing > 0 {
        warnings.push(format!(
            "{missing} references to missing blocks were omitted."
        ));
    }
    for (what, n) in &ctx.skipped {
        warnings.push(format!("{n} × {what} not shown."));
    }
    if ctx.ole > 0 {
        warnings.push(format!(
            "{} embedded OLE objects are shown as frames.",
            ctx.ole
        ));
    }
    warnings.extend(ctx.notes);
    warnings.push("MacCAD keeps geometry, layers, linetypes, text styles, blocks, attributes and dimension graphics. Layouts, extended data, dictionaries and other non-graphical objects are not kept when the drawing is saved.".into());
    doc.validate()?;
    Ok((doc, warnings))
}

fn resolve_image(shape: &mut Shape, defs: &HashMap<String, String>) {
    if let Shape::Image { path, .. } = shape {
        if let Some(h) = path.strip_prefix('#') {
            *path = defs.get(h).cloned().unwrap_or_default();
        }
    }
}

fn read_header(p: &[Pair], ctx: &mut Context) {
    let mut k = 0;
    while k < p.len() {
        if p[k].0 == 9 {
            let name = p[k].1.trim();
            let value = p.get(k + 1).map(|q| q.1).unwrap_or("");
            match name {
                "$INSUNITS" => ctx.insunits = int(value),
                "$MEASUREMENT" => ctx.measurement = int(value),
                "$LTSCALE" => {
                    let v = num(value);
                    if v > EPS {
                        ctx.header.ltscale = v;
                    }
                }
                "$PDMODE" => ctx.header.pdmode = int(value) as i32,
                "$PDSIZE" => ctx.header.pdsize = num(value),
                "$DIMASZ" => {
                    ctx.arrow.entry(String::new()).or_insert(num(value));
                }
                _ => {}
            }
        }
        k += 1;
    }
}

fn read_table_entry(kind: &str, p: &[Pair], ctx: &mut Context) {
    let name = get(p, 2).unwrap_or("").trim().to_string();
    match kind {
        "LAYER" if !name.is_empty() => {
            let raw = geti(p, 62, 7);
            let flags = geti(p, 70, 0);
            let color = get(p, 420)
                .map(|v| true_color(int(v)))
                .unwrap_or_else(|| aci(raw.unsigned_abs().clamp(1, 255) as u8));
            let weight = match geti(p, 370, -3) {
                w if (0..=211).contains(&w) => w as f32 / 100.0,
                _ => 0.25,
            };
            let lt = get(p, 6)
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .unwrap_or("Continuous");
            ctx.layers.push(Layer {
                name,
                color,
                visible: raw >= 0,
                locked: flags & 4 != 0,
                line_type: line_type_name(lt),
                line_weight: weight,
                frozen: flags & 1 != 0,
                plot: geti(p, 290, 1) != 0,
            });
        }
        "LTYPE"
            if !name.is_empty()
                && !["BYBLOCK", "BYLAYER", "CONTINUOUS"]
                    .contains(&name.to_ascii_uppercase().as_str()) =>
        {
            let pattern: Vec<f64> = p
                .iter()
                .filter(|(c, _)| *c == 49)
                .map(|(_, v)| num(v))
                .take(64)
                .collect();
            ctx.linetypes.insert(
                name,
                LineTypeDef {
                    description: get(p, 3).unwrap_or("").to_string(),
                    pattern,
                },
            );
        }
        "STYLE" if !name.is_empty() => {
            // TrueType styles name their family in ACAD extended data.
            let mut font = get(p, 3).unwrap_or("").trim().to_string();
            if let Some(k) = p.iter().position(|(c, v)| *c == 1001 && v.trim() == "ACAD") {
                if let Some((1000, family)) = p.get(k + 1).copied() {
                    if !family.trim().is_empty() {
                        font = family.trim().to_string();
                    }
                }
            }
            ctx.text_styles.insert(
                style_name(Some(&name)),
                TextStyle {
                    font,
                    width_factor: Some(getf(p, 41, 1.0)).filter(|w| *w > EPS).unwrap_or(1.0),
                    oblique: getf(p, 50, 0.0).to_radians(),
                    height: getf(p, 40, 0.0),
                },
            );
        }
        "DIMSTYLE" if !name.is_empty() => {
            let scale = Some(getf(p, 40, 1.0)).filter(|s| *s > EPS).unwrap_or(1.0);
            ctx.arrow.insert(name, getf(p, 41, 0.18) * scale);
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aci_matches_published_anchor_values() {
        let px = |i: u8| {
            aci(i)
                .iter()
                .take(3)
                .map(|c| (c * 255.0).round() as i32)
                .collect::<Vec<_>>()
        };
        assert_eq!(px(1), vec![255, 0, 0]);
        assert_eq!(px(10), vec![255, 0, 0]);
        assert_eq!(px(11), vec![255, 127, 127]);
        assert_eq!(px(12), vec![204, 0, 0]);
        assert_eq!(px(30), vec![255, 127, 0]);
        assert_eq!(px(250), vec![51, 51, 51]);
    }
    #[test]
    fn text_codes_decode() {
        assert_eq!(decode_text("%%c50 %%d %%p1 \\U+00E9"), "Ø50 ° ±1 é");
        assert_eq!(
            paragraph_indent("\\pi8.53070E+006;{\\LINTERIOR}"),
            (8.5307e6, 0.0)
        );
        assert_eq!(paragraph_indent("\\pxi-3,l3,t4;Item"), (-3.0, 3.0));
        assert_eq!(paragraph_indent("{\\fArial|b0;Plain}"), (0.0, 0.0));
        assert_eq!(
            plain_mtext("\\pi11400;{\\LEXISTING PLAN }\\PSecond \\S1/2;"),
            "EXISTING PLAN \nSecond 1/2"
        );
    }
}

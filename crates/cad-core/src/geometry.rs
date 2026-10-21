use serde::{Deserialize, Serialize};
use std::ops::{Add, Mul, Sub};

pub const EPS: f64 = 1e-9;

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}
impl Point {
    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
    pub fn length(self) -> f64 {
        self.x.hypot(self.y)
    }
    pub fn distance(self, other: Self) -> f64 {
        (self - other).length()
    }
    pub fn dot(self, other: Self) -> f64 {
        self.x * other.x + self.y * other.y
    }
    pub fn cross(self, other: Self) -> f64 {
        self.x * other.y - self.y * other.x
    }
    pub fn finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite() && self.x.abs() <= 1e12 && self.y.abs() <= 1e12
    }
}
impl Add for Point {
    type Output = Self;
    fn add(self, rhs: Self) -> Self {
        Self::new(self.x + rhs.x, self.y + rhs.y)
    }
}
impl Sub for Point {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self {
        Self::new(self.x - rhs.x, self.y - rhs.y)
    }
}
impl Mul<f64> for Point {
    type Output = Self;
    fn mul(self, k: f64) -> Self {
        Self::new(self.x * k, self.y * k)
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
pub struct Bounds {
    pub min: Point,
    pub max: Point,
}
impl Bounds {
    pub fn from_points(points: &[Point]) -> Option<Self> {
        let first = *points.first()?;
        let mut b = Self {
            min: first,
            max: first,
        };
        for p in points {
            b.min.x = b.min.x.min(p.x);
            b.min.y = b.min.y.min(p.y);
            b.max.x = b.max.x.max(p.x);
            b.max.y = b.max.y.max(p.y);
        }
        Some(b)
    }
    pub fn union(self, b: Self) -> Self {
        Self {
            min: Point::new(self.min.x.min(b.min.x), self.min.y.min(b.min.y)),
            max: Point::new(self.max.x.max(b.max.x), self.max.y.max(b.max.y)),
        }
    }
    pub fn contains(self, p: Point) -> bool {
        p.x >= self.min.x && p.x <= self.max.x && p.y >= self.min.y && p.y <= self.max.y
    }
}

pub fn nearest_on_segment(p: Point, a: Point, b: Point) -> Point {
    let d = b - a;
    let t = if d.dot(d) <= EPS * EPS {
        0.0
    } else {
        ((p - a).dot(d) / d.dot(d)).clamp(0.0, 1.0)
    };
    a + d * t
}
pub fn intersection(a: Point, b: Point, c: Point, d: Point) -> Option<Point> {
    let u = b - a;
    let v = d - c;
    let cross = u.cross(v);
    if cross.abs() <= EPS * u.length().max(1.0) * v.length().max(1.0) {
        return None;
    }
    Some(a + u * ((c - a).cross(v) / cross))
}

/// A bulge is tan(included angle / 4); the sign determines sweep direction.
pub fn bulge_arc(a: Point, b: Point, bulge: f64) -> Option<(Point, f64, f64, f64)> {
    if bulge.abs() < EPS || a.distance(b) < EPS {
        return None;
    }
    let d = b - a;
    let center = (a + b) * 0.5 + Point::new(-d.y, d.x) * ((1.0 - bulge * bulge) / (4.0 * bulge));
    Some((
        center,
        center.distance(a),
        (a.y - center.y).atan2(a.x - center.x),
        4.0 * bulge.atan(),
    ))
}

#[derive(Clone, Copy, Debug)]
pub struct Transform {
    pub a: f64,
    pub b: f64,
    pub c: f64,
    pub d: f64,
    pub tx: f64,
    pub ty: f64,
}
impl Transform {
    pub const IDENTITY: Self = Self {
        a: 1.0,
        b: 0.0,
        c: 0.0,
        d: 1.0,
        tx: 0.0,
        ty: 0.0,
    };
    pub fn apply(self, p: Point) -> Point {
        Point::new(
            self.a * p.x + self.c * p.y + self.tx,
            self.b * p.x + self.d * p.y + self.ty,
        )
    }
    pub fn compose(self, rhs: Self) -> Self {
        Self {
            a: self.a * rhs.a + self.c * rhs.b,
            b: self.b * rhs.a + self.d * rhs.b,
            c: self.a * rhs.c + self.c * rhs.d,
            d: self.b * rhs.c + self.d * rhs.d,
            tx: self.a * rhs.tx + self.c * rhs.ty + self.tx,
            ty: self.b * rhs.tx + self.d * rhs.ty + self.ty,
        }
    }
    pub fn translation(p: Point) -> Self {
        Self {
            tx: p.x,
            ty: p.y,
            ..Self::IDENTITY
        }
    }
    pub fn rotation(base: Point, angle: f64, scale: f64) -> Self {
        let (s, c) = angle.sin_cos();
        Self::translation(base)
            .compose(Self {
                a: c * scale,
                b: s * scale,
                c: -s * scale,
                d: c * scale,
                ..Self::IDENTITY
            })
            .compose(Self::translation(base * -1.0))
    }
    pub fn mirror(a: Point, b: Point) -> Option<Self> {
        let d = b - a;
        if d.length() < EPS {
            return None;
        }
        let u = d * (1.0 / d.length());
        Some(
            Self::translation(a)
                .compose(Self {
                    a: 2.0 * u.x * u.x - 1.0,
                    b: 2.0 * u.x * u.y,
                    c: 2.0 * u.x * u.y,
                    d: 2.0 * u.y * u.y - 1.0,
                    ..Self::IDENTITY
                })
                .compose(Self::translation(a * -1.0)),
        )
    }
    pub fn determinant(self) -> f64 {
        self.a * self.d - self.b * self.c
    }
    pub fn scale(self) -> f64 {
        self.a.hypot(self.b)
    }
    pub fn angle(self) -> f64 {
        self.b.atan2(self.a)
    }
}

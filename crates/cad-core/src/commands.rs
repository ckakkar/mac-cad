use crate::geometry::{intersection, nearest_on_segment, Bounds, Point, Transform, EPS};
use crate::model::{Document, Entity, Layer, Shape, Vertex};
use crate::render::{entity_batch, entity_bounds, Batch};
use rstar::{RTree, RTreeObject, AABB};
use serde_json::{json, Value};
use std::collections::BTreeSet;

#[derive(Clone, PartialEq)]
struct Indexed {
    id: u64,
    envelope: AABB<[f64; 2]>,
}
impl RTreeObject for Indexed {
    type Envelope = AABB<[f64; 2]>;
    fn envelope(&self) -> Self::Envelope {
        self.envelope
    }
}
#[derive(Clone)]
pub(crate) struct Settings {
    pub(crate) layers: Vec<Layer>,
    pub(crate) units: String,
    pub(crate) current_layer: String,
    pub(crate) blocks: crate::model::Blocks,
}
impl Settings {
    pub(crate) fn of(d: &Document) -> Self {
        Self {
            layers: d.layers.clone(),
            units: d.units.clone(),
            current_layer: d.current_layer.clone(),
            blocks: d.blocks.clone(),
        }
    }
    fn apply(&self, d: &mut Document) {
        d.layers = self.layers.clone();
        d.units = self.units.clone();
        d.current_layer = self.current_layer.clone();
        d.blocks = self.blocks.clone();
    }
}
struct Change {
    before: Vec<Entity>,
    after: Vec<Entity>,
    settings: Option<(Settings, Settings)>,
    before_revision: u64,
    after_revision: u64,
    label: String,
}

pub struct Engine {
    pub doc: Document,
    pub selected: BTreeSet<u64>,
    index: RTree<Indexed>,
    undo: Vec<Change>,
    redo: Vec<Change>,
    pub revision: u64,
    next_revision: u64,
    saved_revision: u64,
    pub diagnostics: Vec<String>,
    /// Name of the action being dispatched, recorded with its undo step.
    label: String,
}
impl Default for Engine {
    fn default() -> Self {
        Self::new(Document::default()).expect("default document is valid")
    }
}
impl Engine {
    pub fn new(mut doc: Document) -> Result<Self, String> {
        doc.validate()?;
        doc.format_version = 2;
        let mut e = Self {
            doc,
            selected: BTreeSet::new(),
            index: RTree::new(),
            undo: Vec::new(),
            redo: Vec::new(),
            revision: 0,
            next_revision: 1,
            saved_revision: 0,
            diagnostics: Vec::new(),
            label: String::new(),
        };
        e.reindex();
        Ok(e)
    }
    fn indexed(&self, e: &Entity) -> Option<Indexed> {
        let b = entity_bounds(&self.doc, e)?;
        Some(Indexed {
            id: e.id,
            envelope: AABB::from_corners([b.min.x, b.min.y], [b.max.x, b.max.y]),
        })
    }
    pub fn reindex(&mut self) {
        self.index = RTree::bulk_load(
            self.doc
                .entities
                .values()
                .filter_map(|e| self.indexed(e))
                .collect(),
        );
    }
    pub(crate) fn editable(&self, e: &Entity) -> bool {
        self.doc
            .layer(&e.layer)
            .is_some_and(|l| l.shown() && !l.locked)
    }
    fn visible(&self, e: &Entity) -> bool {
        self.doc.layer(&e.layer).is_some_and(|l| l.shown())
    }
    /// Drawing extents; construction lines are infinite and excluded, as in AutoCAD.
    pub fn bounds(&self) -> Option<Bounds> {
        self.doc
            .entities
            .values()
            .filter(|e| self.visible(e) && !matches!(e.shape, Shape::XLine { .. }))
            .filter_map(|e| entity_bounds(&self.doc, e))
            .reduce(|a, b| a.union(b))
    }
    pub(crate) fn ids_in(&self, b: Bounds) -> Vec<u64> {
        self.index
            .locate_in_envelope_intersecting(&AABB::from_corners(
                [b.min.x, b.min.y],
                [b.max.x, b.max.y],
            ))
            .map(|e| e.id)
            .collect()
    }
    pub fn batch(&self, b: Bounds, tolerance: f64) -> Batch {
        self.batch_mode(b, tolerance, true)
    }
    pub fn batch_mode(&self, b: Bounds, tolerance: f64, highlight: bool) -> Batch {
        let mut batch = Batch::default();
        for id in self.ids_in(b) {
            let e = &self.doc.entities[&id];
            if !self.visible(e) {
                continue;
            }
            let mut eb = entity_batch(&self.doc, e, tolerance);
            if highlight && self.selected.contains(&id) {
                for s in &mut eb.segments {
                    s.color = [0.29, 0.67, 1.0, 1.0];
                }
                for t in &mut eb.triangles {
                    t.color = [0.29, 0.67, 1.0, t.color[3].min(0.45)];
                }
                for l in &mut eb.labels {
                    l.color = [0.29, 0.67, 1.0, 1.0];
                }
            }
            batch.segments.extend(eb.segments);
            batch.triangles.extend(eb.triangles);
            batch.labels.extend(eb.labels);
        }
        batch
    }
    pub fn pick(&self, p: Point, tolerance: f64) -> Option<u64> {
        let b = Bounds {
            min: p - Point::new(tolerance, tolerance),
            max: p + Point::new(tolerance, tolerance),
        };
        self.ids_in(b)
            .into_iter()
            .filter_map(|id| {
                let e = &self.doc.entities[&id];
                if !self.editable(e) {
                    return None;
                }
                let batch = crate::render::entity_geometry(&self.doc, e, tolerance * 0.1);
                let mut d = batch
                    .segments
                    .iter()
                    .map(|s| {
                        nearest_on_segment(p, Point::new(s.ax, s.ay), Point::new(s.bx, s.by))
                            .distance(p)
                    })
                    .fold(f64::INFINITY, f64::min);
                for l in &batch.labels {
                    if let Some(b) = entity_bounds(&self.doc, e) {
                        if b.contains(p) {
                            d = d.min(p.distance(l.at).min(tolerance * 0.9));
                        }
                    }
                }
                // Clicking inside a fill selects it, as with solid hatches.
                if d > tolerance
                    && batch.triangles.iter().any(|t| {
                        let (a, b, c) = (
                            Point::new(t.ax, t.ay),
                            Point::new(t.bx, t.by),
                            Point::new(t.cx, t.cy),
                        );
                        let s = |p1: Point, p2: Point| (p2 - p1).cross(p - p1);
                        let (d1, d2, d3) = (s(a, b), s(b, c), s(c, a));
                        !((d1 < 0.0 || d2 < 0.0 || d3 < 0.0) && (d1 > 0.0 || d2 > 0.0 || d3 > 0.0))
                    })
                {
                    d = tolerance * 0.95;
                }
                if d <= tolerance {
                    Some((id, d))
                } else {
                    None
                }
            })
            .min_by(|a, b| a.1.total_cmp(&b.1).then(a.0.cmp(&b.0)))
            .map(|v| v.0)
    }
    pub fn snap(&self, p: Point, tolerance: f64) -> Value {
        self.precise_snap(p, tolerance, None)
    }
    pub(crate) fn commit(
        &mut self,
        mut after: Vec<Entity>,
        remove: Vec<u64>,
        settings: Option<Settings>,
    ) -> Result<(), String> {
        for e in &after {
            e.shape.validate()?;
            if !e.style.valid()
                || self.doc.layer(&e.layer).is_none()
                    && settings
                        .as_ref()
                        .is_none_or(|s| !s.layers.iter().any(|l| l.name == e.layer))
            {
                return Err("Invalid entity properties or layer".into());
            }
            if e.id == 0 || e.id > 9_007_199_254_740_991 {
                return Err("Entity ID limit reached".into());
            }
        }
        if self.doc.entities.len() + after.len() > 1_000_000 + remove.len() {
            return Err("Drawing exceeds the alpha's entity limit".into());
        }
        let ids: BTreeSet<_> = after.iter().map(|e| e.id).chain(remove).collect();
        let before: Vec<_> = ids
            .iter()
            .filter_map(|id| self.doc.entities.get(id).cloned())
            .collect();
        let old_settings = settings.as_ref().map(|_| Settings::of(&self.doc));
        let old_next_id = self.doc.next_id;
        self.doc.next_id = after
            .iter()
            .map(|e| e.id + 1)
            .max()
            .unwrap_or(old_next_id)
            .max(old_next_id);
        let mut index_old = Vec::new();
        for e in &before {
            if let Some(i) = self.indexed(e) {
                index_old.push(i);
            }
        }
        for id in &ids {
            self.doc.entities.remove(id);
        }
        for e in &after {
            self.doc.entities.insert(e.id, e.clone());
        }
        if let Some(s) = &settings {
            s.apply(&mut self.doc);
        }
        // Referenced blocks and layers are validated before committing metadata.
        if let Err(error) = if settings.is_some() {
            self.doc.validate()
        } else {
            Ok(())
        } {
            for id in ids {
                self.doc.entities.remove(&id);
            }
            for e in before {
                self.doc.entities.insert(e.id, e);
            }
            if let Some(s) = old_settings {
                s.apply(&mut self.doc);
            }
            self.doc.next_id = old_next_id;
            return Err(error);
        }
        if before == after && settings.is_none() {
            return Ok(());
        }
        if settings.is_some() {
            self.reindex();
        } else {
            for i in index_old {
                self.index.remove(&i);
            }
            for e in &after {
                if let Some(i) = self.indexed(e) {
                    self.index.insert(i);
                }
            }
        }
        let change = Change {
            before,
            after: std::mem::take(&mut after),
            settings: old_settings.zip(settings),
            before_revision: self.revision,
            after_revision: self.next_revision,
            label: if self.label.is_empty() {
                "Edit".into()
            } else {
                self.label.clone()
            },
        };
        self.revision = self.next_revision;
        self.next_revision += 1;
        self.undo.push(change);
        if self.undo.len() > 256 {
            self.undo.remove(0);
        }
        self.redo.clear();
        self.selected
            .retain(|id| self.doc.entities.contains_key(id));
        Ok(())
    }
    pub fn add(&mut self, shapes: Vec<Shape>) -> Result<Vec<u64>, String> {
        if !self
            .doc
            .layer(&self.doc.current_layer)
            .is_some_and(|l| l.shown() && !l.locked)
        {
            return Err("Current layer is hidden or locked".into());
        }
        for s in &shapes {
            s.validate()?;
            if let Shape::Insert { block, .. } = s {
                if !self.doc.blocks.contains_key(block) {
                    return Err(format!("Unknown block: {block}"));
                }
            }
        }
        let mut entities = Vec::new();
        let mut ids = Vec::new();
        for (i, shape) in shapes.into_iter().enumerate() {
            let id = self.doc.next_id + i as u64;
            ids.push(id);
            entities.push(Entity {
                id,
                layer: self.doc.current_layer.clone(),
                style: Default::default(),
                shape,
            });
        }
        self.commit(entities, Vec::new(), None)?;
        Ok(ids)
    }
    pub(crate) fn selection(&self) -> Result<Vec<Entity>, String> {
        let v: Vec<_> = self
            .selected
            .iter()
            .filter_map(|id| self.doc.entities.get(id))
            .filter(|e| self.editable(e))
            .cloned()
            .collect();
        if v.is_empty() {
            Err("Select editable objects first".into())
        } else {
            Ok(v)
        }
    }
    fn transform(&mut self, t: Transform, copy: bool) -> Result<(), String> {
        let source = self.selection()?;
        let mut after = Vec::new();
        for (i, mut e) in source.into_iter().enumerate() {
            if let Shape::Insert { .. } = e.shape {
                if t.determinant() < 0.0 {
                    return Err("Explode blocks before mirroring them".into());
                }
            }
            e.shape = e.shape.transformed(t);
            if copy {
                e.id = self.doc.next_id + i as u64;
            }
            after.push(e);
        }
        self.commit(after, Vec::new(), None)
    }
    pub fn undo(&mut self, redo: bool) -> Result<(), String> {
        let change = if redo {
            self.redo.pop()
        } else {
            self.undo.pop()
        }
        .ok_or("Nothing to undo/redo")?;
        for e in change.before.iter().chain(&change.after) {
            self.doc.entities.remove(&e.id);
        }
        let entities = if redo { &change.after } else { &change.before };
        for e in entities {
            self.doc.entities.insert(e.id, e.clone());
        }
        if let Some((a, b)) = &change.settings {
            if redo {
                b.apply(&mut self.doc)
            } else {
                a.apply(&mut self.doc)
            }
        }
        self.revision = if redo {
            change.after_revision
        } else {
            change.before_revision
        };
        self.selected.clear();
        self.reindex();
        if redo {
            self.undo.push(change)
        } else {
            self.redo.push(change)
        }
        Ok(())
    }
    pub fn state(&self) -> Value {
        json!({"revision":self.revision,"dirty":self.revision!=self.saved_revision,"count":self.doc.entities.len(),"selected":self.selected,"layers":self.doc.layers,"current_layer":self.doc.current_layer,"units":self.doc.units,"bounds":self.bounds(),"can_undo":!self.undo.is_empty(),"can_redo":!self.redo.is_empty(),"diagnostics":self.diagnostics,"blocks":self.doc.blocks.keys().filter(|k|!k.starts_with('*')).take(5000).collect::<Vec<_>>(),"selection":self.selected.iter().take(100).filter_map(|id|self.doc.entities.get(id)).collect::<Vec<_>>(),"grips":self.selection_grips(),"undo_label":self.undo.last().map(|c|&c.label),"redo_label":self.redo.last().map(|c|&c.label)})
    }
    pub fn dispatch(&mut self, v: Value) -> Result<Value, String> {
        self.label = action_label(&v);
        if let Some(result) = self.drafting_dispatch(&v) {
            return result;
        }
        match v["op"].as_str().unwrap_or("") {
            "state" => Ok(self.state()),
            "command" => {
                self.command(v["text"].as_str().ok_or("Missing command")?)?;
                Ok(self.state())
            }
            "undo_if_revision" => {
                if v["revision"].as_u64() != Some(self.revision) {
                    return Err("The drawing changed after that line segment. Finish or cancel LINE before undoing other edits.".into());
                }
                self.undo(false)?;
                Ok(self.state())
            }
            "grip" => {
                let id = v["id"].as_u64().ok_or("Missing grip object")?;
                let index = v["index"].as_u64().ok_or("Missing grip index")? as usize;
                let to: Point =
                    serde_json::from_value(v["point"].clone()).map_err(|e| e.to_string())?;
                self.move_grip(id, index, to)?;
                Ok(self.state())
            }
            "grip_preview" => {
                let id = v["id"].as_u64().ok_or("Missing grip object")?;
                let index = v["index"].as_u64().ok_or("Missing grip index")? as usize;
                let to: Point =
                    serde_json::from_value(v["point"].clone()).map_err(|e| e.to_string())?;
                let tol = v["tolerance"].as_f64().unwrap_or(0.1);
                if !tol.is_finite() || tol <= 0.0 {
                    return Err("Invalid preview tolerance".into());
                }
                Ok(json!({"segments":self.grip_preview(id, index, to, tol)}))
            }
            "hover" => {
                let p: Point =
                    serde_json::from_value(v["point"].clone()).map_err(|e| e.to_string())?;
                let tol = v["tolerance"].as_f64().unwrap_or(10.0);
                if !p.finite() || !tol.is_finite() || tol <= 0.0 {
                    return Err("Invalid hover point/tolerance".into());
                }
                Ok(json!({"id":self.pick(p, tol)}))
            }
            "add" => {
                let shapes: Vec<Shape> =
                    serde_json::from_value(v["shapes"].clone()).map_err(|e| e.to_string())?;
                self.add(shapes)?;
                Ok(self.state())
            }
            "pick" => {
                let p: Point =
                    serde_json::from_value(v["point"].clone()).map_err(|e| e.to_string())?;
                let tol = v["tolerance"].as_f64().unwrap_or(10.0);
                if !p.finite() || !tol.is_finite() || tol <= 0.0 {
                    return Err("Invalid pick point/tolerance".into());
                }
                let id = self.pick(p, tol);
                if let Some(mode) = v["mode"].as_str() {
                    self.apply_selection(id.into_iter().collect(), mode)?;
                    return Ok(self.state());
                }
                if !v["extend"].as_bool().unwrap_or(false) {
                    self.selected.clear();
                }
                if let Some(id) = id {
                    if !self.selected.insert(id) {
                        self.selected.remove(&id);
                    }
                }
                Ok(self.state())
            }
            "select" => {
                self.selected.clear();
                for id in v["ids"].as_array().ok_or("Missing IDs")? {
                    if let Some(id) = id.as_u64() {
                        if self.doc.entities.get(&id).is_some_and(|e| self.editable(e)) {
                            self.selected.insert(id);
                        }
                    }
                }
                Ok(self.state())
            }
            "select_all" => {
                self.selected = self
                    .doc
                    .entities
                    .values()
                    .filter(|e| self.editable(e))
                    .map(|e| e.id)
                    .collect();
                Ok(self.state())
            }
            "select_last" => {
                self.selected = self
                    .doc
                    .entities
                    .values()
                    .rev()
                    .find(|e| self.editable(e))
                    .map(|e| e.id)
                    .into_iter()
                    .collect();
                Ok(self.state())
            }
            "snap" => {
                let p: Point =
                    serde_json::from_value(v["point"].clone()).map_err(|e| e.to_string())?;
                let tol = v["tolerance"].as_f64().unwrap_or(10.0);
                if !p.finite() || !tol.is_finite() || tol <= 0.0 {
                    return Err("Invalid snap point/tolerance".into());
                }
                let base = v
                    .get("base")
                    .filter(|v| !v.is_null())
                    .map(|v| serde_json::from_value::<Point>(v.clone()).map_err(|e| e.to_string()))
                    .transpose()?;
                if base.is_some_and(|b| !b.finite()) {
                    return Err("Invalid snap base".into());
                }
                let modes = v["modes"].as_array().map(|m| {
                    m.iter()
                        .filter_map(|k| k.as_str().map(String::from))
                        .collect::<Vec<_>>()
                });
                Ok(self.precise_snap_modes(p, tol, base, modes.as_deref()))
            }
            "serialize" => serde_json::to_value(&self.doc).map_err(|e| e.to_string()),
            "load" => {
                let doc: Document =
                    serde_json::from_value(v["document"].clone()).map_err(|e| e.to_string())?;
                *self = Self::new(doc)?;
                Ok(self.state())
            }
            // Native files are read and written here so large drawings never
            // cross the bridge as one JSON value.
            "save_native" => {
                let path = std::path::Path::new(v["path"].as_str().ok_or("Missing path")?);
                let bytes = serde_json::to_vec(&self.doc).map_err(|e| e.to_string())?;
                let temporary = path.with_extension("maccad-partial");
                std::fs::write(&temporary, bytes)
                    .and_then(|_| std::fs::rename(&temporary, path))
                    .map_err(|e| {
                        let _ = std::fs::remove_file(&temporary);
                        format!("The drawing could not be saved: {e}")
                    })?;
                Ok(json!({}))
            }
            "open_native" => {
                let path = std::path::Path::new(v["path"].as_str().ok_or("Missing path")?);
                let len = std::fs::metadata(path).map_err(|e| e.to_string())?.len();
                if len > 2 * 1024 * 1024 * 1024 {
                    return Err("Native drawing exceeds the 2 GiB limit".into());
                }
                let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
                let doc: Document = serde_json::from_slice(&bytes)
                    .map_err(|e| format!("This is not a readable MacCAD drawing: {e}"))?;
                *self = Self::new(doc)?;
                Ok(self.state())
            }
            "saved" => {
                if v["revision"].as_u64() == Some(self.revision) {
                    self.saved_revision = self.revision;
                }
                Ok(self.state())
            }
            "layer" => {
                let name = v["name"].as_str().ok_or("Missing layer")?;
                let mut settings = Settings::of(&self.doc);
                if let Some(new) = v["rename"].as_str() {
                    return self.rename_layer(name, new).map(|_| self.state());
                }
                if v["delete"].as_bool() == Some(true) {
                    if name == "0" || name == self.doc.current_layer {
                        return Err("Layer 0 and the current layer cannot be deleted".into());
                    }
                    if self.doc.entities.values().any(|e| e.layer == name) {
                        return Err(
                            "Only empty layers can be deleted; move or erase its objects first"
                                .into(),
                        );
                    }
                    let before = settings.layers.len();
                    settings.layers.retain(|l| l.name != name);
                    if settings.layers.len() == before {
                        return Err("Unknown layer".into());
                    }
                    self.commit(Vec::new(), Vec::new(), Some(settings))?;
                    return Ok(self.state());
                }
                if v["isolate"].as_bool() == Some(true) {
                    if !settings.layers.iter().any(|l| l.name == name) {
                        return Err("Unknown layer".into());
                    }
                    for l in &mut settings.layers {
                        l.visible = l.name == name;
                    }
                    settings.current_layer = name.into();
                    self.commit(Vec::new(), Vec::new(), Some(settings))?;
                    return Ok(self.state());
                }
                if v["create"].as_bool() == Some(true) {
                    valid_layer_name(name)?;
                    if settings.layers.iter().any(|l| l.name == name) {
                        return Err("Layer already exists".into());
                    }
                    settings
                        .layers
                        .push(Layer::new(name, [0.65, 0.78, 0.91, 1.0]));
                    settings.current_layer = name.into();
                } else {
                    let l = settings
                        .layers
                        .iter_mut()
                        .find(|l| l.name == name)
                        .ok_or("Unknown layer")?;
                    if let Some(a) = v["visible"].as_bool() {
                        l.visible = a;
                    }
                    if let Some(a) = v["locked"].as_bool() {
                        l.locked = a;
                    }
                    if let Some(c) = v.get("color") {
                        l.color = serde_json::from_value(c.clone()).map_err(|e| e.to_string())?;
                    }
                    if let Some(s) = v["line_type"].as_str() {
                        l.line_type = s.into();
                    }
                    if let Some(w) = v["line_weight"].as_f64() {
                        l.line_weight = w as f32;
                    }
                    if v["current"].as_bool() == Some(true) {
                        settings.current_layer = name.into();
                    }
                }
                self.commit(Vec::new(), Vec::new(), Some(settings))?;
                self.selected.retain(|id| {
                    self.doc.entities.get(id).is_some_and(|e| {
                        self.doc
                            .layer(&e.layer)
                            .is_some_and(|l| l.shown() && !l.locked)
                    })
                });
                Ok(self.state())
            }
            "import_dxf" => {
                let path = v["path"].as_str().ok_or("Missing path")?;
                let (doc, diagnostics) = crate::exchange::import_dxf(std::path::Path::new(path))?;
                *self = Self::new(doc)?;
                self.diagnostics = diagnostics;
                self.revision = self.next_revision;
                self.next_revision += 1;
                Ok(self.state())
            }
            "export_dxf" => {
                let path = v["path"].as_str().ok_or("Missing path")?;
                let warnings = crate::exchange::export_dxf(&self.doc, std::path::Path::new(path))?;
                Ok(json!({"diagnostics":warnings}))
            }
            _ => Err("Unknown operation".into()),
        }
    }
    pub fn command(&mut self, text: &str) -> Result<(), String> {
        if let Some(result) = self.drafting_command(text) {
            return result;
        }
        let tokens: Vec<_> = text.split_whitespace().collect();
        let name = tokens
            .first()
            .ok_or("Enter a command")?
            .to_ascii_uppercase();
        let args = &tokens[1..];
        let point = |i: usize| -> Result<Point, String> {
            parse_point(args.get(i).copied().ok_or("Missing coordinate (x,y)")?)
        };
        let number = |i: usize| -> Result<f64, String> {
            parse_number(args.get(i).copied().ok_or("Missing number")?)
        };
        let shape = match name.as_str() {
            "L" | "LINE" => Some(Shape::Line {
                a: point(0)?,
                b: point(1)?,
            }),
            "REC" | "RECT" | "RECTANGLE" => {
                let a = point(0)?;
                let b = point(1)?;
                Some(Shape::Polyline {
                    vertices: [a, Point::new(b.x, a.y), b, Point::new(a.x, b.y)]
                        .into_iter()
                        .map(|point| Vertex::new(point, 0.0))
                        .collect(),
                    closed: true,
                })
            }
            "PL" | "PLINE" | "POLYLINE" => {
                let closed = args.last().is_some_and(|s| s.eq_ignore_ascii_case("close"));
                let count = args.len() - usize::from(closed);
                let mut vertices = Vec::new();
                for token in &args[..count] {
                    let (p, b) = token.split_once(':').map_or((*token, 0.0), |(p, b)| {
                        (p, parse_number(b).unwrap_or(f64::NAN))
                    });
                    vertices.push(Vertex::new(parse_point(p)?, b));
                }
                Some(Shape::Polyline { vertices, closed })
            }
            "C" | "CIRCLE" => Some(Shape::Circle {
                center: point(0)?,
                radius: number(1)?,
            }),
            "A" | "ARC" => Some(Shape::Arc {
                center: point(0)?,
                radius: number(1)?,
                start: number(2)?.to_radians(),
                sweep: number(3)?.to_radians(),
            }),
            "TEXT" | "T" => {
                if args.len() < 3 {
                    return Err("TEXT x,y height words…".into());
                }
                Some(Shape::text(point(0)?, args[2..].join(" "), number(1)?, 0.0))
            }
            "DIM" | "DIMLINEAR" | "DIMALIGNED" => Some(Shape::Dimension {
                a: point(0)?,
                b: point(1)?,
                offset: number(2)?,
                aligned: name == "DIMALIGNED",
            }),
            "HATCH" => {
                if args.len() < 4 {
                    return Err("HATCH solid|diagonal spacing x,y x,y x,y …".into());
                }
                let boundary = args[2..]
                    .iter()
                    .map(|s| parse_point(s))
                    .collect::<Result<Vec<_>, _>>()?;
                Some(Shape::Hatch {
                    boundary,
                    pattern: args[0].to_ascii_lowercase(),
                    spacing: number(1)?,
                })
            }
            "INSERT" => Some(Shape::insert(
                args.first()
                    .ok_or("INSERT name x,y [scale] [degrees]")?
                    .to_string(),
                point(1)?,
                if args.len() > 2 { number(2)? } else { 1.0 },
                if args.len() > 3 {
                    number(3)?.to_radians()
                } else {
                    0.0
                },
            )),
            _ => None,
        };
        if let Some(shape) = shape {
            self.add(vec![shape])?;
            return Ok(());
        }
        match name.as_str() {
            "U" | "UNDO" => self.undo(false),
            "REDO" => self.undo(true),
            "E" | "ERASE" | "DELETE" => {
                let ids = self.selection()?.iter().map(|e| e.id).collect();
                self.commit(Vec::new(), ids, None)
            }
            "M" | "MOVE" => self.transform(Transform::translation(point(0)?), false),
            "CO" | "COPY" => self.transform(Transform::translation(point(0)?), true),
            "RO" | "ROTATE" => self.transform(
                Transform::rotation(point(0)?, number(1)?.to_radians(), 1.0),
                false,
            ),
            "SC" | "SCALE" => {
                let scale = number(1)?;
                if scale <= EPS {
                    return Err("Scale must be positive".into());
                }
                self.transform(Transform::rotation(point(0)?, 0.0, scale), false)
            }
            "MI" | "MIRROR" => {
                if args.get(2).is_some_and(|v| {
                    !v.eq_ignore_ascii_case("keep") && !v.eq_ignore_ascii_case("delete")
                }) {
                    return Err("MIRROR axis-x,y axis-x,y [keep|delete]".into());
                }
                self.transform(
                    Transform::mirror(point(0)?, point(1)?)
                        .ok_or("Mirror axis needs two distinct points")?,
                    !args
                        .get(2)
                        .is_some_and(|v| v.eq_ignore_ascii_case("delete")),
                )
            }
            "O" | "OFFSET" => {
                let distance = number(0)?;
                let mut shapes = Vec::new();
                for e in self.selection()? {
                    match e.shape {
                        Shape::Line { a, b } => {
                            let d = b - a;
                            let n = Point::new(-d.y, d.x) * (distance / d.length());
                            shapes.push(Shape::Line { a: a + n, b: b + n });
                        }
                        Shape::Circle { center, radius } => shapes.push(Shape::Circle {
                            center,
                            radius: radius + distance,
                        }),
                        _ => return Err("Offset currently supports lines and circles".into()),
                    }
                }
                self.add(shapes)?;
                Ok(())
            }
            "TR" | "TRIM" | "EX" | "EXTEND" => {
                let c = point(0)?;
                let d = point(1)?;
                if c.distance(d) < EPS {
                    return Err("Boundary requires distinct points".into());
                }
                let pick = point(2)?;
                let extend = name == "EX" || name == "EXTEND";
                let mut out = Vec::new();
                for mut e in self.selection()? {
                    if let Shape::Line { a, b } = e.shape {
                        let p = intersection(a, b, c, d).ok_or("Line is parallel to boundary")?;
                        let t = (p - a).dot(b - a) / (b - a).dot(b - a);
                        if extend {
                            if (0.0..=1.0).contains(&t) {
                                return Err("Boundary does not extend this line".into());
                            }
                            e.shape = if t < 0.0 {
                                Shape::Line { a: p, b }
                            } else {
                                Shape::Line { a, b: p }
                            };
                        } else {
                            if !(EPS..1.0 - EPS).contains(&t) {
                                return Err("Boundary does not cross this segment".into());
                            }
                            e.shape = if (pick - a).dot(b - a) < (p - a).dot(b - a) {
                                Shape::Line { a: p, b }
                            } else {
                                Shape::Line { a, b: p }
                            };
                        }
                        out.push(e);
                    } else {
                        return Err("Trim/extend currently support lines".into());
                    }
                }
                self.commit(out, Vec::new(), None)
            }
            "UNITS" => {
                let mut s = Settings::of(&self.doc);
                s.units = args.first().ok_or("UNITS mm|cm|m|in|ft")?.to_string();
                self.commit(Vec::new(), Vec::new(), Some(s))
            }
            "BLOCK" => {
                let name = args.first().ok_or("BLOCK name base-x,base-y")?;
                let base = point(1)?;
                if name.starts_with('*') || self.doc.blocks.contains_key(*name) {
                    return Err("Choose a new block name".into());
                }
                let selected = self.selection()?;
                let mut s = Settings::of(&self.doc);
                std::sync::Arc::make_mut(&mut s.blocks).insert(
                    name.to_string(),
                    selected
                        .iter()
                        .map(|e| {
                            e.shape
                                .transformed(Transform::translation(base * -1.0))
                                .into()
                        })
                        .collect(),
                );
                let id = self.doc.next_id;
                let insert = Entity {
                    id,
                    layer: self.doc.current_layer.clone(),
                    style: Default::default(),
                    shape: Shape::insert(name.to_string(), base, 1.0, 0.0),
                };
                self.commit(
                    vec![insert],
                    selected.iter().map(|e| e.id).collect(),
                    Some(s),
                )
            }
            "EXPLODE" => {
                let selected = self.selection()?;
                let mut remove = Vec::new();
                let mut after = Vec::new();
                for e in selected {
                    if let Shape::Insert { .. } = e.shape {
                        after.extend(
                            self.doc
                                .explode_insert(&e, self.doc.next_id + after.len() as u64)?,
                        );
                        remove.push(e.id);
                    } else {
                        return Err("Explode currently supports static blocks".into());
                    }
                }
                self.commit(after, remove, None)
            }
            _ => Err(format!("Unknown command: {name}")),
        }
    }
}
impl Engine {
    fn rename_layer(&mut self, name: &str, new: &str) -> Result<(), String> {
        let new = new.trim();
        valid_layer_name(new)?;
        if name == "0" {
            return Err("Layer 0 cannot be renamed".into());
        }
        if new != name && self.doc.layer(new).is_some() {
            return Err("A layer with that name already exists".into());
        }
        let mut settings = Settings::of(&self.doc);
        let layer = settings
            .layers
            .iter_mut()
            .find(|l| l.name == name)
            .ok_or("Unknown layer")?;
        layer.name = new.into();
        if settings.current_layer == name {
            settings.current_layer = new.into();
        }
        let after = self
            .doc
            .entities
            .values()
            .filter(|e| e.layer == name)
            .map(|e| Entity {
                layer: new.into(),
                ..e.clone()
            })
            .collect();
        self.commit(after, Vec::new(), Some(settings))
    }
}
fn valid_layer_name(name: &str) -> Result<(), String> {
    // AutoCAD reserves these characters in symbol-table names.
    if name.trim().is_empty()
        || name.len() > 255
        || name.trim() != name
        || name
            .chars()
            .any(|c| "<>/\\\":;?*|,=`".contains(c) || c.is_control())
    {
        return Err(
            "Layer names need 1–255 characters, without < > / \\ \" : ; ? * | , = `".into(),
        );
    }
    Ok(())
}
/// Undo/redo menu name for a request, using AutoCAD's command vocabulary.
fn action_label(v: &Value) -> String {
    let op = v["op"].as_str().unwrap_or("");
    let name = match op {
        "command" => v["text"]
            .as_str()
            .and_then(|t| t.split_whitespace().next())
            .unwrap_or("")
            .to_ascii_uppercase(),
        "add" => v["shapes"][0]["kind"]
            .as_str()
            .unwrap_or("")
            .to_ascii_uppercase(),
        "layer" => return "Layer Change".into(),
        "properties" => return "Property Change".into(),
        "paste" => return "Paste".into(),
        "grip" => return "Grip Edit".into(),
        "import_dxf" => return "Import".into(),
        _ => return String::new(),
    };
    let label = match name.as_str() {
        "L" | "LINE" => "Line",
        "PL" | "PLINE" | "POLYLINE" => "Polyline",
        "REC" | "RECT" | "RECTANG" | "RECTANGLE" => "Rectangle",
        "C" | "CIRCLE" | "CIRCLE2" | "CIRCLE3" => "Circle",
        "A" | "ARC" | "ARC3" => "Arc",
        "EL" | "ELLIPSE" => "Ellipse",
        "SPL" | "SPLINE" => "Spline",
        "POL" | "POLYGON" => "Polygon",
        "PO" | "POINT" => "Point",
        "T" | "TEXT" | "MT" | "MTEXT" => "Text",
        "DIM" | "DIMLINEAR" | "DIMALIGNED" | "DIMRADIUS" | "DIMDIAMETER" | "DIMENSION"
        | "RADIAL_DIMENSION" => "Dimension",
        "LEADER" | "MLEADER" => "Leader",
        "H" | "HATCH" => "Hatch",
        "M" | "MOVE" => "Move",
        "CO" | "CP" | "COPY" => "Copy",
        "RO" | "ROTATE" => "Rotate",
        "SC" | "SCALE" => "Scale",
        "MI" | "MIRROR" => "Mirror",
        "O" | "OFFSET" => "Offset",
        "TR" | "TRIM" => "Trim",
        "EX" | "EXTEND" => "Extend",
        "F" | "FILLET" => "Fillet",
        "CHA" | "CHAMFER" => "Chamfer",
        "J" | "JOIN" => "Join",
        "BR" | "BREAK" => "Break",
        "S" | "STRETCH" => "Stretch",
        "AR" | "ARRAYRECT" | "ARRAYPOLAR" => "Array",
        "X" | "EXPLODE" => "Explode",
        "E" | "ERASE" | "DELETE" => "Erase",
        "BLOCK" => "Block",
        "I" | "INSERT" => "Insert",
        "REVERSE" => "Reverse",
        "CLOSE" => "Close",
        "OPEN" => "Open",
        "UNITS" => "Units",
        "CHPROP" | "MATCHPROP" | "MA" => "Property Change",
        "OVERKILL" => "Overkill",
        "PURGE" => "Purge",
        n if n.starts_with("LAY") => "Layer Change",
        _ => "",
    };
    label.into()
}
pub fn parse_number(s: &str) -> Result<f64, String> {
    let n = s
        .parse::<f64>()
        .map_err(|_| format!("Invalid number: {s}"))?;
    if n.is_finite() && n.abs() <= 1e12 {
        Ok(n)
    } else {
        Err("Number is outside supported range".into())
    }
}
pub fn parse_point(s: &str) -> Result<Point, String> {
    let (x, y) = s.split_once(',').ok_or("Use x,y coordinates")?;
    let p = Point::new(parse_number(x)?, parse_number(y)?);
    if p.finite() {
        Ok(p)
    } else {
        Err("Invalid coordinate".into())
    }
}

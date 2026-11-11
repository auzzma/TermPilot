//! Causal, field-level merge. Arrival order and wall clocks never select a winner.
use super::{err, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub type Vector = BTreeMap<String, u64>;
pub fn covers(a: &Vector, b: &Vector) -> bool {
    b.iter()
        .all(|(writer, seq)| a.get(writer).copied().unwrap_or(0) >= *seq)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub struct Dot {
    pub writer: String,
    pub seq: u64,
}
impl Dot {
    pub fn observed(&self, v: &Vector) -> bool {
        v.get(&self.writer).copied().unwrap_or(0) >= self.seq
    }
    pub fn key(&self) -> String {
        format!("{}:{}", self.writer, self.seq)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Operation {
    pub version: u32,
    pub library: String,
    pub scope: String,
    pub dot: Dot,
    pub basis: Vector,
    pub collection: String,
    pub record: String,
    #[serde(flatten)]
    pub action: Action,
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum Action {
    Patch {
        fields: BTreeMap<String, Value>,
    },
    Delete {
        recovery: Value,
        retention_days: Option<u32>,
        deleted_at: String,
    },
    Purge {
        recycle_ids: Vec<String>,
    },
    Restored {
        recycle_ids: Vec<String>,
        mapping: BTreeMap<String, String>,
    },
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Candidate {
    pub dot: Dot,
    pub basis: Vector,
    pub value: Value,
}
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct Record {
    pub fields: BTreeMap<String, Vec<Candidate>>,
    pub deletes: BTreeMap<String, Candidate>,
}
impl Record {
    pub fn deleted(&self) -> bool {
        !self.deletes.is_empty()
    }
    pub fn value(&self) -> Value {
        Value::Object(
            self.fields
                .iter()
                .filter_map(|(field, candidates)| {
                    candidates.last().map(|c| (field.clone(), c.value.clone()))
                })
                .collect(),
        )
    }
    pub fn conflicted(&self) -> bool {
        if self.deleted() {
            self.fields
                .values()
                .flatten()
                .any(|c| self.deletes.values().all(|d| !c.dot.observed(&d.basis)))
        } else {
            self.fields.values().any(|c| {
                c.iter()
                    .any(|v| c.first().is_some_and(|f| f.value != v.value))
            })
        }
    }
}
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Recycle {
    pub collection: String,
    pub record: String,
    pub deletion: Dot,
    pub recovery: Option<Value>,
    pub retention_days: Option<u32>,
    pub deleted_at: String,
    pub published_at: Option<i64>,
    pub purged: bool,
    pub restored: BTreeMap<String, String>,
}
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq)]
pub struct State {
    pub frontier: Vector,
    pub records: BTreeMap<String, Record>,
    pub recycle: BTreeMap<String, Recycle>,
    // Hashes detect a reused operation ID with different content, including after restart.
    pub fingerprints: BTreeMap<String, String>,
    pub waiting: BTreeMap<String, Operation>,
    pub purged: BTreeMap<String, Dot>,
    pub restored: BTreeMap<String, BTreeMap<String, String>>,
    #[serde(default)]
    pub published: BTreeMap<String, i64>,
}
pub fn record_key(collection: &str, id: &str) -> String {
    format!("{collection}/{id}")
}
pub fn hash(value: &impl Serialize) -> String {
    hex::encode(Sha256::digest(
        serde_json::to_vec(value).expect("serializable sync value"),
    ))
}
impl State {
    pub fn receive(&mut self, op: Operation, library: &str, scope: &str) -> Result<bool> {
        if op.version != 1 || op.library != library || op.scope != scope {
            return Err(err("syncVersion", "同步库、范围或协议版本不匹配。"));
        }
        if op.dot.seq == 0
            || op.dot.writer.is_empty()
            || op.record.is_empty()
            || op.basis.get(&op.dot.writer).copied().unwrap_or(0) != op.dot.seq - 1
        {
            return Err(err("syncOperation", "同步操作的因果序号无效。"));
        }
        let id = op.dot.key();
        let digest = hash(&op);
        if let Some(old) = self.fingerprints.get(&id) {
            if old != &digest {
                return Err(err(
                    "syncCollision",
                    "相同操作 ID 对应不同内容，已停止同步。",
                ));
            }
            return Ok(false);
        }
        if op.dot.observed(&self.frontier) {
            return Err(err("syncRollback", "操作早于已验证快照但缺少校验信息。"));
        }
        self.fingerprints.insert(id.clone(), digest);
        self.waiting.insert(id, op);
        loop {
            let next = self
                .waiting
                .iter()
                .find(|(_, p)| covers(&self.frontier, &p.basis))
                .map(|(id, _)| id.clone());
            let Some(id) = next else { break };
            let op = self.waiting.remove(&id).unwrap();
            self.apply(&op);
            self.frontier.insert(op.dot.writer.clone(), op.dot.seq);
        }
        Ok(true)
    }
    fn apply(&mut self, op: &Operation) {
        let record = self
            .records
            .entry(record_key(&op.collection, &op.record))
            .or_default();
        match &op.action {
            Action::Patch { fields } => {
                for (field, value) in fields {
                    let candidates = record.fields.entry(field.clone()).or_default();
                    if candidates.iter().any(|c| op.dot.observed(&c.basis)) {
                        continue;
                    }
                    candidates.retain(|c| !c.dot.observed(&op.basis));
                    candidates.push(Candidate {
                        dot: op.dot.clone(),
                        basis: op.basis.clone(),
                        value: value.clone(),
                    });
                    candidates.sort_by(|a, b| a.dot.cmp(&b.dot));
                }
            }
            Action::Delete {
                recovery,
                retention_days,
                deleted_at,
            } => {
                let id = op.dot.key();
                record.deletes.insert(
                    id.clone(),
                    Candidate {
                        dot: op.dot.clone(),
                        basis: op.basis.clone(),
                        value: Value::Null,
                    },
                );
                let purged = self.purged.contains_key(&id);
                self.recycle.insert(
                    id.clone(),
                    Recycle {
                        collection: op.collection.clone(),
                        record: op.record.clone(),
                        deletion: op.dot.clone(),
                        recovery: (!purged).then(|| recovery.clone()),
                        retention_days: *retention_days,
                        deleted_at: deleted_at.clone(),
                        published_at: self.published.get(&id).copied(),
                        purged,
                        restored: self.restored.get(&id).cloned().unwrap_or_default(),
                    },
                );
            }
            Action::Purge { recycle_ids } => {
                for id in recycle_ids {
                    self.purged
                        .entry(id.clone())
                        .and_modify(|dot| *dot = dot.clone().min(op.dot.clone()))
                        .or_insert_with(|| op.dot.clone());
                    if let Some(item) = self.recycle.get_mut(id) {
                        item.purged = true;
                        item.recovery = None;
                    }
                }
            }
            Action::Restored {
                recycle_ids,
                mapping,
            } => {
                for id in recycle_ids {
                    let actions: BTreeMap<String, String> = mapping
                        .iter()
                        .map(|(old, new)| (format!("{}:{old}", op.dot.key()), new.clone()))
                        .collect();
                    self.restored
                        .entry(id.clone())
                        .or_default()
                        .extend(actions.clone());
                    if let Some(item) = self.recycle.get_mut(id) {
                        item.restored.extend(actions);
                    }
                }
            }
        }
    }

    pub fn merge(&mut self, other: State) -> Result<()> {
        other.validate_snapshot()?;
        if !other.waiting.is_empty() {
            return Err(err("syncSnapshot", "快照边界包含未完成的依赖。"));
        }
        for (id, hash) in &other.fingerprints {
            if self.fingerprints.get(id).is_some_and(|h| h != hash) {
                return Err(err("syncCollision", "快照包含不一致的操作 ID。"));
            }
        }
        for (key, record) in other.records {
            let target = self.records.entry(key).or_default();
            for (field, candidates) in record.fields {
                let values = target.fields.entry(field).or_default();
                for candidate in candidates {
                    if !candidate.dot.observed(&other.frontier) {
                        return Err(err("syncSnapshot", "快照包含边界之外的记录。"));
                    }
                    if values
                        .iter()
                        .any(|v| v.dot == candidate.dot && v != &candidate)
                    {
                        return Err(err("syncCollision", "快照中同一字段版本的内容不一致。"));
                    }
                    if values
                        .iter()
                        .any(|v| v.dot == candidate.dot || candidate.dot.observed(&v.basis))
                    {
                        continue;
                    }
                    values.retain(|v| !v.dot.observed(&candidate.basis));
                    values.push(candidate);
                }
                values.sort_by(|a, b| a.dot.cmp(&b.dot));
            }
            target.deletes.extend(record.deletes);
        }
        self.fingerprints.extend(other.fingerprints);
        for (writer, seq) in other.frontier {
            self.frontier
                .entry(writer)
                .and_modify(|s| *s = (*s).max(seq))
                .or_insert(seq);
        }
        for (id, dot) in other.purged {
            self.purged
                .entry(id)
                .and_modify(|d| *d = d.clone().min(dot.clone()))
                .or_insert(dot);
        }
        for (id, mapping) in other.restored {
            self.restored.entry(id).or_default().extend(mapping);
        }
        for (id, item) in other.recycle {
            self.recycle.entry(id).or_insert(item);
        }
        for (id, time) in other.published {
            self.publication(&id, time);
        }
        for (id, item) in &mut self.recycle {
            if self.purged.contains_key(id) {
                item.purged = true;
                item.recovery = None;
            }
            if let Some(mapping) = self.restored.get(id) {
                item.restored.extend(mapping.clone());
            }
        }
        self.waiting
            .retain(|_, op| !op.dot.observed(&self.frontier));
        loop {
            let next = self
                .waiting
                .iter()
                .find(|(_, op)| covers(&self.frontier, &op.basis))
                .map(|(id, _)| id.clone());
            let Some(id) = next else { break };
            let op = self.waiting.remove(&id).unwrap();
            self.apply(&op);
            self.frontier.insert(op.dot.writer.clone(), op.dot.seq);
        }
        Ok(())
    }
    fn validate_snapshot(&self) -> Result<()> {
        let fail = || err("syncSnapshot", "快照的因果边界或版本证明不完整。");
        let mut counts = BTreeMap::<String, u64>::new();
        for (id, hash) in &self.fingerprints {
            let (writer, seq) = id.rsplit_once(':').ok_or_else(fail)?;
            let seq = seq.parse::<u64>().map_err(|_| fail())?;
            if seq == 0
                || seq > self.frontier.get(writer).copied().unwrap_or(0)
                || hash.len() != 64
                || !hash.bytes().all(|b| b.is_ascii_hexdigit())
            {
                return Err(fail());
            }
            *counts.entry(writer.into()).or_default() += 1;
        }
        if counts != self.frontier {
            return Err(fail());
        }
        let valid = |candidate: &Candidate| {
            candidate.dot.seq > 0
                && candidate.dot.observed(&self.frontier)
                && covers(&self.frontier, &candidate.basis)
                && candidate
                    .basis
                    .get(&candidate.dot.writer)
                    .copied()
                    .unwrap_or(0)
                    == candidate.dot.seq - 1
        };
        for record in self.records.values() {
            if !record.fields.values().flatten().all(valid) || !record.deletes.values().all(valid) {
                return Err(fail());
            }
            if record.deletes.iter().any(|(id, c)| id != &c.dot.key()) {
                return Err(fail());
            }
        }
        for (id, item) in &self.recycle {
            if id != &item.deletion.key()
                || !item.deletion.observed(&self.frontier)
                || !self
                    .records
                    .get(&record_key(&item.collection, &item.record))
                    .is_some_and(|r| r.deletes.contains_key(id))
            {
                return Err(fail());
            }
        }
        Ok(())
    }
    pub fn publication(&mut self, id: &str, time: i64) {
        let value = self
            .published
            .entry(id.into())
            .and_modify(|t| *t = (*t).min(time))
            .or_insert(time);
        if let Some(item) = self.recycle.get_mut(id) {
            item.published_at = Some(*value);
        }
    }
}

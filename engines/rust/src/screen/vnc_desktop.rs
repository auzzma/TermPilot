//! Negotiated RFB ExtendedDesktopSize / SetDesktopSize support.
//! Never send message 251 before the server advertises the extension, and never
//! replace a multi-monitor topology with a single screen as a side effect.
use anyhow::{ensure, Result};
use serde_json::{json, Value};

#[derive(Default)]
pub(super) struct Desktop {
    screen: Option<(u32, u32)>, // Preserve the server's screen id and flags.
    pending: Option<(String, u16, u16)>,
}
impl Desktop {
    pub fn update(&mut self, reason: usize, status: usize, width: usize, height: usize, screens: &[u8]) -> Result<Vec<Value>> {
        ensure!(screens.len() % 16 == 0 && screens.len() <= 255 * 16, "vncInvalidData");
        if reason == 1 && status != 0 {
            // All layout fields are undefined on failure, but its body was consumed.
            let event=self.pending.as_ref().map(|p| json!({"kind":"vncResizeResult","requestID":p.0,
                "accepted":false,"pending":status==4,"code":match status {
                    1=>"vncResizeProhibited",2=>"vncResizeResources",3=>"vncResizeLayout",4=>"vncResizeForwarded",_=>"vncResizeRejected"
                }}));
            if status != 4 { self.pending = None; }
            return Ok(event.into_iter().collect());
        }
        ensure!((1..=8192).contains(&width) && (1..=8192).contains(&height) && width*height<=16_777_216, "vncInvalidData");
        let mut ids=std::collections::HashSet::new();
        self.screen=None;
        for s in screens.chunks_exact(16) {
            let id=u32::from_be_bytes(s[0..4].try_into()?);
            let x=u16::from_be_bytes(s[4..6].try_into()?) as usize;
            let y=u16::from_be_bytes(s[6..8].try_into()?) as usize;
            let w=u16::from_be_bytes(s[8..10].try_into()?) as usize;
            let h=u16::from_be_bytes(s[10..12].try_into()?) as usize;
            let flags=u32::from_be_bytes(s[12..16].try_into()?);
            ensure!(ids.insert(id) && w>0 && h>0 && x+w<=width && y+h<=height, "vncInvalidData");
            if screens.len()==16 && (x,y,w,h)==(0,0,width,height) { self.screen=Some((id,flags)); }
        }
        let mut events=vec![json!({"kind":"vncCapabilities","canResize":self.screen.is_some(),
            "code":if self.screen.is_some(){""}else{"vncResizeTopology"}})];
        if self.pending.as_ref().is_some_and(|p| reason==1 || (p.1 as usize,p.2 as usize)==(width,height)) {
            let (id,w,h)=self.pending.take().unwrap();
            let accepted=(w as usize,h as usize)==(width,height);
            events.push(json!({"kind":"vncResizeResult","requestID":id,"accepted":accepted,
                "code":if accepted{""}else{"vncResizeRejected"}}));
        }
        Ok(events)
    }
    pub fn request(&mut self, id: &str, width: u64, height: u64) -> std::result::Result<Vec<u8>, &'static str> {
        let (screen,flags)=self.screen.ok_or("vncResizeUnsupported")?;
        if self.pending.is_some() { return Err("vncResizeBusy"); }
        if uuid::Uuid::parse_str(id).is_err() || !(1..=8192).contains(&width) || !(1..=8192).contains(&height) || width*height>16_777_216 { return Err("vncResizeLayout"); }
        let (w,h)=(width as u16,height as u16);
        let mut message=vec![251,0];message.extend(w.to_be_bytes());message.extend(h.to_be_bytes());message.extend([1,0]);
        message.extend(screen.to_be_bytes());message.extend([0;4]);message.extend(w.to_be_bytes());message.extend(h.to_be_bytes());message.extend(flags.to_be_bytes());
        self.pending=Some((id.to_owned(),w,h));
        Ok(message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn screen(id:u32,w:u16,h:u16)->Vec<u8> { [id.to_be_bytes().to_vec(),vec![0;4],w.to_be_bytes().to_vec(),h.to_be_bytes().to_vec(),42u32.to_be_bytes().to_vec()].concat() }
    #[test]
    fn resize_requires_negotiation_preserves_identity_and_waits_for_confirmation() {
        let mut d=Desktop::default();let id=uuid::Uuid::new_v4().to_string();
        assert_eq!(d.request(&id,1920,1080).unwrap_err(),"vncResizeUnsupported");
        assert_eq!(d.update(0,0,1280,720,&screen(9,1280,720)).unwrap()[0]["canResize"],true);
        let request=d.request(&id,1920,1080).unwrap();
        assert_eq!(request,[vec![251,0,7,128,4,56,1,0],screen(9,1920,1080)].concat());
        assert_eq!(d.request(&id,1280,720).unwrap_err(),"vncResizeBusy");
        assert_eq!(d.update(1,0,1920,1080,&screen(9,1920,1080)).unwrap()[1]["requestID"],id);
    }
    #[test]
    fn rejection_does_not_parse_undefined_layout_and_multiscreen_is_not_replaced() {
        let mut d=Desktop::default();let id=uuid::Uuid::new_v4().to_string();
        d.update(0,0,1280,720,&screen(9,1280,720)).unwrap();d.request(&id,1920,1080).unwrap();
        assert_eq!(d.update(1,1,0,0,&[0;16]).unwrap()[0]["code"],"vncResizeProhibited");
        d.request(&id,1920,1080).unwrap();
        assert_eq!(d.update(1,4,0,0,&[]).unwrap()[0]["pending"],true);
        assert_eq!(d.update(0,0,1920,1080,&screen(9,1920,1080)).unwrap()[1]["accepted"],true);
        assert_eq!(d.update(0,0,1280,720,&[screen(9,1280,720),screen(10,1280,720)].concat()).unwrap()[0]["canResize"],false);
        assert!(d.request(&id,1920,1080).is_err());
    }
}

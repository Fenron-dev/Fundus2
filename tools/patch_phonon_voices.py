"""Small, checked adapter for the pinned upstream C API, applied only in CI.

Keeps model and voice directories separate on CPU and Core ML. No model,
embedding, or third-party source is copied into the public repository.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1]) / "ptts-ffi" / "src"


def replace(text, before, after):
    if text.count(before) != 1:
        raise RuntimeError(f"Pinned Phonon source changed: {before[:80]!r}")
    return text.replace(before, after, 1)


cpu = (root / "cpu.rs").read_text()
signature = "pub fn open(dir: &Path, unit: u32, lang: &str) -> Result<Self, String> {"
extended = "pub fn open(dir: &Path, unit: u32, lang: &str, external: &[(String, std::path::PathBuf)]) -> Result<Self, String> {"
cpu = replace(cpu, signature, extended)
cpu = replace(cpu, "        let synth = builder.build()", "        for (name, path) in external {\n            builder = builder.add_voice(name.clone(), path.clone());\n        }\n        let synth = builder.build()")
# Match Phonon's desktop defaults and vary the flow sampler between utterances.
# Reusing the upstream default seed (42) for every reader segment made adjacent
# paragraphs use the same prosodic realization, which sounded conspicuously flat.
cpu = replace(cpu, "    frame_size: usize,\n}", "    frame_size: usize,\n    seed: u64,\n}")
cpu = replace(cpu, "            frame_size,\n        })", "            frame_size,\n            seed: 4242,\n        })")
cpu = replace(cpu, "        let opts = SpeechOptions { voice: self.voice.clone(), ..Default::default() };", "        let opts = SpeechOptions { voice: self.voice.clone(), ..Default::default() }\n            .temperature(0.3)\n            .seed(self.seed);\n        self.seed = self.seed.wrapping_add(1);")
(root / "cpu.rs").write_text(cpu)

apple = (root / "coreml.rs").read_text()
apple = replace(apple, signature, extended)
apple = replace(apple, "    dir: PathBuf,", "    dir: PathBuf,\n    external: std::collections::BTreeMap<String, PathBuf>,")
apple = replace(apple, '    let w = Weights::open(&dir.join("voices").join(format!("{name}.safetensors")))?;', '    load_voice_file(&dir.join("voices").join(format!("{name}.safetensors")), name)\n}\n\nfn load_voice_file(path: &Path, name: &str) -> Result<Voice, String> {\n    let w = Weights::open(path)?;')
apple = replace(apple, "        let voices = voice_names(dir);", "        let external: std::collections::BTreeMap<String, PathBuf> = external.iter().cloned().collect();\n        let mut voices = voice_names(dir);\n        let extra = external.keys().filter(|name| !voices.contains(name)).cloned().collect::<Vec<_>>();\n        voices.extend(extra);")
apple = replace(apple, '        let voice = load_voice(dir, voices.first().ok_or("no voices in the bundle")?)?;', '        let name = voices.first().ok_or("no voices in the bundle")?;\n        let voice = match external.get(name) { Some(path) => load_voice_file(path, name)?, None => load_voice(dir, name)? };')
apple = replace(apple, "            dir: dir.to_path_buf(),", "            dir: dir.to_path_buf(),\n            external,")
apple = replace(apple, "        self.phonon.set_voice(load_voice(&self.dir, name)?)", "        let voice = match self.external.get(name) { Some(path) => load_voice_file(path, name)?, None => load_voice(&self.dir, name)? };\n        self.phonon.set_voice(voice)")
(root / "coreml.rs").write_text(apple)

ffi = (root / "lib.rs").read_text()
ffi = replace(ffi, '''#[cfg(target_vendor = "apple")]
mod coreml;
#[cfg(target_vendor = "apple")]
use coreml::Engine;
#[cfg(not(target_vendor = "apple"))]
mod cpu;
#[cfg(not(target_vendor = "apple"))]
use cpu::Engine;''', '''#[cfg(target_vendor = "apple")]
mod coreml;
mod cpu;
#[cfg(not(target_vendor = "apple"))]
use cpu::Engine;

// CPU checkpoints from the Phonon studio are also usable on macOS. Core ML
// bundles remain accelerated; their projected `emb` voices differ from raw
// speaker_wavs catalogues and cannot be interchanged without the checkpoint.
#[cfg(target_vendor = "apple")]
enum Engine { Cpu(cpu::Engine), CoreMl(coreml::Engine) }
#[cfg(target_vendor = "apple")]
impl Engine {
    fn open(dir: &Path, unit: u32, lang: &str, voices: &[(String, std::path::PathBuf)]) -> Result<Self, String> {
        if dir.join("bundle.json").is_file() { coreml::Engine::open(dir, unit, lang, voices).map(Self::CoreMl) }
        else { cpu::Engine::open(dir, PTTS_UNIT_CPU, lang, voices).map(Self::Cpu) }
    }
    fn voices(&self) -> &[String] { match self { Self::Cpu(e) => e.voices(), Self::CoreMl(e) => e.voices() } }
    fn languages(&self) -> &[String] { match self { Self::Cpu(e) => e.languages(), Self::CoreMl(e) => e.languages() } }
    fn set_voice(&mut self, name: &str) -> Result<(), String> { match self { Self::Cpu(e) => e.set_voice(name), Self::CoreMl(e) => e.set_voice(name) } }
    fn set_language(&mut self, lang: &str) -> Result<(), String> { match self { Self::Cpu(e) => e.set_language(lang), Self::CoreMl(e) => e.set_language(lang) } }
    fn speak(&mut self, text: &str, sink: &mut dyn FnMut(&[f32]) -> bool) -> Result<PttsResult, String> { match self { Self::Cpu(e) => e.speak(text, sink), Self::CoreMl(e) => e.speak(text, sink) } }
}''')
ffi = replace(ffi, "fn open(dir: &Path, unit: u32, lang: &str) -> Result<PttsHandle, String> {\n    let engine = Engine::open(dir, unit, lang)?;", "fn open(dir: &Path, unit: u32, lang: &str) -> Result<PttsHandle, String> {\n    open_with_voices(dir, unit, lang, &[])\n}\n\nfn open_with_voices(dir: &Path, unit: u32, lang: &str, external: &[(String, std::path::PathBuf)]) -> Result<PttsHandle, String> {\n    let engine = Engine::open(dir, unit, lang, external)?;")
ffi += '''
/// Fundus adapter: external embeddings stay at their original local paths.
/// Same ownership/error contract as ptts_new; catalogue is a UTF-8 JSON array.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ptts_new_with_voices(
    dir: *const c_char, unit: u32, lang: *const c_char, catalogue: *const c_char,
) -> *mut PttsHandle {
    let result = guarded(|| {
        let dir = unsafe { CStr::from_ptr(dir) }.to_string_lossy();
        let lang = unsafe { CStr::from_ptr(lang) }.to_string_lossy();
        let raw = unsafe { CStr::from_ptr(catalogue) }.to_string_lossy();
        let entries: Vec<serde_json::Value> = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
        let mut voices = Vec::new();
        for entry in entries {
            let name = entry["name"].as_str().ok_or("voice name missing")?;
            let path = std::path::PathBuf::from(entry["path"].as_str().ok_or("voice path missing")?);
            if !path.is_absolute() || !path.is_file() { return Err("voice file missing".into()); }
            voices.push((name.to_string(), path));
        }
        open_with_voices(Path::new(dir.as_ref()), unit, &lang, &voices)
    });
    match result {
        Ok(h) => Box::into_raw(Box::new(h)),
        Err(e) => { LAST_ERROR.with(|l| *l.borrow_mut() = Some(c_string(&e))); std::ptr::null_mut() }
    }
}
'''
# Keep the upstream unit tests building against the extended internal call.
cpu = (root / "cpu.rs").read_text().replace('Engine::open(Path::new("no-such-checkpoint"), unit, lang)', 'Engine::open(Path::new("no-such-checkpoint"), unit, lang, &[])')
(root / "cpu.rs").write_text(cpu)
(root / "lib.rs").write_text(ffi)
print("Phonon external-voice adapter applied to pinned source.")

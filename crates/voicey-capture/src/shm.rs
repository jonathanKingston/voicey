//! Re-export shared PCM helpers — see `voicey-pcm` for the canonical spec.

pub use voicey_pcm::{
    file_path as shm_path, new_buffer_name, read_f32_samples, remove as remove_shm,
    write_f32_samples, NAME_PREFIX,
};

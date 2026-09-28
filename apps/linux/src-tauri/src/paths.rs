use std::path::PathBuf;

pub fn data_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("coucou");
        }
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".local/share/coucou")
}

pub fn config_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("coucou");
        }
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".config/coucou")
}

pub fn socket_path() -> PathBuf {
    data_dir().join("nb.sock")
}

pub fn hook_script_path() -> PathBuf {
    data_dir().join("nb-hook")
}

pub fn inbox_dir() -> PathBuf {
    data_dir().join("inbox")
}

pub fn log_path() -> PathBuf {
    data_dir().join("coucou.log")
}

pub fn secrets_fallback_path() -> PathBuf {
    data_dir().join("secrets.json")
}

pub fn ensure() -> std::io::Result<()> {
    std::fs::create_dir_all(data_dir())?;
    std::fs::create_dir_all(config_dir())?;
    std::fs::create_dir_all(inbox_dir())?;
    Ok(())
}

pub(crate) struct LockFile {
    path: std::path::PathBuf,
    file: fs_err::File,
}

impl LockFile {
    pub(crate) fn acquire(path: impl Into<std::path::PathBuf>) -> std::io::Result<Self> {
        let path = path.into();
        if let Some(parent) = path.parent() {
            fs_err::create_dir_all(parent)?;
        }
        let file = fs_err::File::create(&path)?;
        file.try_lock()?;
        Ok(Self { path, file })
    }
}

impl Drop for LockFile {
    fn drop(&mut self) {
        let _ = self.file.unlock();
        let _ = fs_err::remove_file(&self.path);
    }
}

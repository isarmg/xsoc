//! Current mount flags; sysinfo's Linux disk object only records this flag on discovery.
use std::{ffi::CString, mem::MaybeUninit, os::unix::ffi::OsStrExt, path::Path};

pub(super) fn current(mount_point: &Path) -> Option<bool> {
    let path = CString::new(mount_point.as_os_str().as_bytes()).ok()?;
    let mut stat = MaybeUninit::<libc::statvfs>::uninit();
    loop {
        // SAFETY: path is NUL-terminated and remains alive during the call; stat is aligned
        // writable storage of the required type. Only a successful call initializes it.
        if unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } == 0 {
            // SAFETY: statvfs returned success and initialized the complete output structure.
            let stat = unsafe { stat.assume_init() };
            return Some(stat.f_flag & libc::ST_RDONLY != 0);
        }
        if std::io::Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            return None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actual_writable_directory_and_unreadable_path_have_distinct_results() {
        let root = tempfile::tempdir().unwrap();
        std::fs::write(root.path().join("probe"), b"read-only flag fixture").unwrap();
        assert_eq!(current(root.path()), Some(false));
        assert_eq!(current(&root.path().join("missing")), None);
        assert_eq!(current(Path::new("invalid\0mount")), None);
    }
}

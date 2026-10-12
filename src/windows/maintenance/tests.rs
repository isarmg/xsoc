#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_sid_is_stable_and_has_five_subauthorities() {
        let sid = service_sid_string().unwrap();
        assert!(sid.starts_with("S-1-5-80-"));
        assert_eq!(sid.split('-').count(), 9);
        assert_eq!(sid, service_sid_string().unwrap());
    }

    // These are native Windows object tests. The maintenance binary already
    // requires administrative restore privileges; the Windows CI runner has
    // the same privileges. Linux cannot substitute for these handle semantics.
    struct RuntimeLogs {
        directory: xcsc::fs_safety::PrivateDirectory,
        logs: PathBuf,
        descriptor: String,
        _temporary: tempfile::TempDir,
    }

    impl RuntimeLogs {
        fn new() -> Self {
            enable_restore_privileges().expect("administrative Windows test token");
            let temporary = tempfile::tempdir().unwrap();
            let root = temporary.path().canonicalize().unwrap().join("state");
            create_system_admin_only_directory(&root, "test state").unwrap();
            secure_state_for_service(&root).unwrap();
            let logs = root.join("logs");
            create_system_admin_only_directory(&logs, "test logs").unwrap();
            let sid = service_sid_string().unwrap();
            let descriptor =
                managed_state_security_descriptor(Some(&sid)).replacen("O:SY", "O:LS", 1);
            set_managed_security_descriptor(&logs, &descriptor).unwrap();
            let directory = xcsc::fs_safety::PrivateDirectory::open_with_windows_access(
                &logs,
                xcsc::fs_safety::WindowsPrivateAccess::for_service(&sid, "S-1-5-19").unwrap(),
            )
            .unwrap();
            let fixture = Self {
                directory,
                logs,
                descriptor,
                _temporary: temporary,
            };
            for name in [
                ".xsoc.jsonl.writer.lock",
                ".xsoc.jsonl.read.lock",
                "xsoc.jsonl",
            ] {
                fixture.write(name, &[]);
            }
            validate_runtime_log_files(&fixture.directory).unwrap();
            fixture
        }

        fn write(&self, name: &str, bytes: &[u8]) -> PathBuf {
            let path = self.logs.join(name);
            fs::write(&path, bytes).unwrap();
            set_managed_security_descriptor(&path, &self.descriptor).unwrap();
            path
        }
    }

    struct ExclusiveByteLock {
        file: fs::File,
        overlapped: windows::Win32::System::IO::OVERLAPPED,
    }

    impl ExclusiveByteLock {
        fn open(path: &Path) -> Self {
            use windows::Win32::Storage::FileSystem::{
                LOCKFILE_EXCLUSIVE_LOCK, LOCKFILE_FAIL_IMMEDIATELY, LockFileEx,
            };
            let file = fs::OpenOptions::new()
                .read(true)
                .write(true)
                .share_mode((FILE_SHARE_READ | FILE_SHARE_WRITE).0)
                .open(path)
                .unwrap();
            let mut overlapped = windows::Win32::System::IO::OVERLAPPED::default();
            // SAFETY: The owned synchronous file and initialized offset0
            // descriptor remain live; this intentionally locks one byte past
            // EOF for an empty file, reproducing the reported native failure.
            unsafe {
                LockFileEx(
                    HANDLE(file.as_raw_handle()),
                    LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                    Some(0),
                    1,
                    0,
                    &mut overlapped,
                )
            }
            .unwrap();
            Self { file, overlapped }
        }
    }

    impl Drop for ExclusiveByteLock {
        fn drop(&mut self) {
            // SAFETY: This exact owned file acquired this offset/length lock.
            let _ = unsafe {
                windows::Win32::Storage::FileSystem::UnlockFileEx(
                    HANDLE(self.file.as_raw_handle()),
                    Some(0),
                    1,
                    0,
                    &mut self.overlapped,
                )
            };
        }
    }

    #[test]
    fn exclusive_empty_runtime_log_locks_validate_without_byte_reads() {
        let fixture = RuntimeLogs::new();
        let mut locks = Vec::new();
        for name in [".xsoc.jsonl.writer.lock", ".xsoc.jsonl.read.lock"] {
            locks.push(ExclusiveByteLock::open(&fixture.logs.join(name)));
            let entry = xcsc::fs_safety::EntryName::new(name).unwrap();
            let error = fixture
                .directory
                .read_private_bounded(&entry, 0)
                .unwrap_err();
            assert!(
                matches!(error, xcsc::fs_safety::Error::Io(ref native) if native.raw_os_error() == Some(33)),
                "the original EOF byte-read must reproduce ERROR_LOCK_VIOLATION"
            );
        }
        validate_runtime_log_files(&fixture.directory).unwrap();
        drop(locks);
        for name in [".xsoc.jsonl.writer.lock", ".xsoc.jsonl.read.lock"] {
            assert!(
                fixture
                    .directory
                    .read_private_bounded(&xcsc::fs_safety::EntryName::new(name).unwrap(), 0)
                    .unwrap()
                    .is_empty()
            );
        }
    }

    #[test]
    fn runtime_log_names_and_payload_limits_remain_strict() {
        let fixture = RuntimeLogs::new();
        let writer = fixture.write(".xsoc.jsonl.writer.lock", b"x");
        assert!(
            validate_runtime_log_files(&fixture.directory)
                .unwrap_err()
                .to_string()
                .contains("not empty")
        );
        fs::write(writer, []).unwrap();
        let unknown = fixture.write(".xsoc.jsonl.writer.lock.bak", &[]);
        assert!(
            validate_runtime_log_files(&fixture.directory)
                .unwrap_err()
                .to_string()
                .contains("Unrecognized")
        );
        fs::remove_file(unknown).unwrap();
        let payload = fixture.logs.join("xsoc.jsonl");
        let file = fs::OpenOptions::new().write(true).open(&payload).unwrap();
        file.set_len(8 * 1024 * 1024 + 1).unwrap();
        drop(file);
        assert!(
            validate_runtime_log_files(&fixture.directory).is_err(),
            "ordinary log still has its 8MiB read budget"
        );
        fs::write(&payload, b"record\n").unwrap();
        let lock = ExclusiveByteLock::open(&payload);
        assert!(
            validate_runtime_log_files(&fixture.directory).is_err(),
            "ordinary payload range locks must not be bypassed"
        );
        drop(lock);
        validate_runtime_log_files(&fixture.directory).unwrap();
    }

    #[test]
    fn runtime_log_lock_still_rejects_wrong_owner_acl_and_hard_links() {
        let fixture = RuntimeLogs::new();
        let path = fixture.logs.join(".xsoc.jsonl.read.lock");
        set_managed_security_descriptor(&path, &fixture.descriptor.replacen("O:LS", "O:SY", 1))
            .unwrap();
        assert!(
            validate_runtime_log_files(&fixture.directory).is_err(),
            "privileged owner is not the declared LocalService payload owner"
        );
        set_managed_security_descriptor(&path, &fixture.descriptor).unwrap();
        let widened = format!(
            "{}(A;;FA;;;BU)",
            managed_security_descriptor_for_target(&fixture.descriptor, false)
        );
        set_managed_security_descriptor(&path, &widened).unwrap();
        assert!(
            validate_runtime_log_files(&fixture.directory).is_err(),
            "ambient write access must still be rejected"
        );
        set_managed_security_descriptor(&path, &fixture.descriptor).unwrap();
        let alias = fixture.logs.parent().unwrap().join("outside-alias");
        fs::hard_link(&path, &alias).unwrap();
        assert!(
            validate_runtime_log_files(&fixture.directory).is_err(),
            "zero length cannot bypass the single-link invariant"
        );
        fs::remove_file(alias).unwrap();
        validate_runtime_log_files(&fixture.directory).unwrap();
    }

    #[test]
    fn runtime_log_lock_reparse_points_are_not_followed() {
        let fixture = RuntimeLogs::new();
        let path = fixture.logs.join(".xsoc.jsonl.read.lock");
        let target = fixture.logs.parent().unwrap().join("outside-empty-file");
        fs::write(&target, []).unwrap();
        fs::remove_file(&path).unwrap();
        std::os::windows::fs::symlink_file(&target, &path)
            .expect("administrative Windows symlink test");
        assert!(
            validate_runtime_log_files(&fixture.directory).is_err(),
            "a named empty target never authorizes a reparse entry"
        );
    }
}

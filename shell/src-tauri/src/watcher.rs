//! Watching the chosen folders: a change where indexing reads asks the index helper to sync, two seconds after the last
//! one (a camera import or an unzip is a burst of events); in code search's folders a minute after the code goes quiet
//! (ten at most), as on the Mac, so the code index doesn't follow every save. `notify` uses ReadDirectoryChangesW on Windows, inotify on
//! Linux, FSEvents on a Mac. Changes where the crawl never goes are passed over (the engine's `Rules.isWalked`): hidden
//! folders (a leading dot, or Windows' hidden flag, which AppData has), developer folders, `.noindex` folders, skipped
//! folders, and DigUp's own index. With a home folder chosen, other apps' caches would ask for a sync every few seconds.

use notify::{RecursiveMode, Watcher};
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// Folders the crawl never walks into, by name: the engine's `Rules.skippedFolderNames`.
const DEVELOPER_FOLDERS: [&str; 8] =
    ["node_modules", "bower_components", "venv", "site-packages", "__pycache__", "DerivedData", "Pods", "Carthage"];

pub struct FolderWatcher {
    _watcher: Option<notify::RecommendedWatcher>,
    cancelled: Arc<AtomicBool>,
}

impl FolderWatcher {
    /// Watches `folders` (less `skipped` inside them); `changed` runs on the watcher's own thread after each burst of
    /// changes: once nothing has changed for `quiet`, or `longest` after the burst began. Dropping it stops.
    pub fn start(folders: &[PathBuf], skipped: Vec<PathBuf>, ignore: Option<PathBuf>, quiet: Duration, longest: Duration,
                 changed: impl Fn() + Send + 'static) -> FolderWatcher {
        let (sender, receiver) = mpsc::sync_channel::<()>(1);
        let cancelled = Arc::new(AtomicBool::new(false));
        let roots = folders.to_vec();
        let watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
            let Ok(event) = result else { return };
            if event.kind.is_access() {
                return;
            }
            let ours = |path: &PathBuf| ignore.as_ref().is_some_and(|folder| path.starts_with(folder));
            // No paths: the system dropped events (an overflow), so anything may have changed.
            if event.paths.is_empty() || event.paths.iter().any(|path| !ours(path) && walked(path, &roots, &skipped)) {
                let _ = sender.try_send(());
            }
        });
        let mut watcher = match watcher {
            Ok(watcher) => watcher,
            Err(error) => {
                eprintln!("digup-shell: can't watch folders: {error}");
                return FolderWatcher { _watcher: None, cancelled };
            }
        };
        for folder in folders {
            if let Err(error) = watcher.watch(folder, RecursiveMode::Recursive) {
                eprintln!("digup-shell: can't watch {}: {error}", folder.display());
            }
        }
        let stopped = cancelled.clone();
        std::thread::spawn(move || {
            'watch: while receiver.recv().is_ok() {
                let began = std::time::Instant::now();
                loop {
                    let Some(remaining) = longest.checked_sub(began.elapsed()) else { break };
                    match receiver.recv_timeout(quiet.min(remaining)) {
                        Ok(()) => {},
                        Err(mpsc::RecvTimeoutError::Timeout) => break,
                        Err(mpsc::RecvTimeoutError::Disconnected) => break 'watch,
                    }
                }
                if stopped.load(Ordering::Acquire) { break; }
                changed();
            }
        });
        FolderWatcher { _watcher: Some(watcher), cancelled }
    }
}

impl Drop for FolderWatcher {
    fn drop(&mut self) { self.cancelled.store(true, Ordering::Release); }
}

/// The crawl reads `path`: it's inside a chosen folder, and nothing on the way to it from there is skipped. A skipped
/// folder counts only inside the chosen folders that contain it (one chosen inside it is read whole).
fn walked(path: &Path, roots: &[PathBuf], skipped: &[PathBuf]) -> bool {
    // These hidden control files change the set of readable source files. Check their enclosing repository/folder,
    // so the normal hidden-cache filter cannot swallow a policy change.
    let control = policy_parent(path);
    let path = control.as_deref().unwrap_or(path);
    roots.iter().any(|root| {
        let Ok(below) = path.strip_prefix(root) else { return false };
        let mut folder = root.clone();
        below.components().all(|part| {
            folder.push(part);
            let name = part.as_os_str().to_string_lossy();
            !(name.starts_with('.')
                || DEVELOPER_FOLDERS.contains(&name.as_ref())
                || name.ends_with(".noindex")
                || skipped.contains(&folder)
                || hidden(&folder))
        })
    })
}

fn policy_parent(path: &Path) -> Option<PathBuf> {
    let name = path.file_name()?.to_string_lossy();
    if name == ".gitignore" || name == ".git" { return path.parent().map(Path::to_path_buf); }
    if path.ends_with(Path::new(".git/info/exclude")) {
        return path.parent()?.parent()?.parent().map(Path::to_path_buf);
    }
    None
}

/// Windows' hidden flag; elsewhere a leading dot is the rule, checked above.
#[cfg(windows)]
fn hidden(path: &Path) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_HIDDEN: u32 = 0x2;
    std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_attributes() & FILE_ATTRIBUTE_HIDDEN != 0)
}

#[cfg(not(windows))]
fn hidden(_: &Path) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::walked;
    use std::path::PathBuf;

    #[test]
    fn walks_where_the_crawl_goes() {
        let home = PathBuf::from("/home/me");
        let roots = vec![home.clone(), home.join("Pictures/.private/shared")];
        let skipped = vec![home.join("Music"), home.join("Music/Mixes")];
        let read = |path: &str| walked(&home.join(path), &roots, &skipped);
        assert!(read("Documents/notes.md"));
        assert!(read("code/app/.gitignore"));
        assert!(read("code/app/.git"));
        assert!(read("code/app/.git/info/exclude"));
        assert!(!read("code/app/.git/objects/abc"));
        assert!(!read("Music/.gitignore"));
        assert!(!read(".cache/thumbnails/x.png"));
        assert!(!read("code/app/node_modules/pkg/index.js"));
        assert!(!read("Archive.noindex/old.pdf"));
        assert!(!read("Music/song.mp3"));
        assert!(!read("Music/Mixes/one.mp3"));
        // A folder chosen inside a hidden or skipped one is read whole.
        assert!(read("Pictures/.private/shared/photo.jpg"));
        assert!(!walked(&PathBuf::from("/elsewhere/file.txt"), &roots, &skipped));
    }
}

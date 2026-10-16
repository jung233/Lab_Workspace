# Project browse directory

Each project can have a device-local directory for browsing its files outside
Lab Workspace. The default parent is the app's Documents directory followed by
`Lab Workspace/项目`; the project directory below it uses a stable project ID
and a readable title. On Windows, a user can choose another existing parent
folder. Lab Workspace creates the project child directory there.

The generated layout is:

```text
<project-id>_<project-title>/
  项目清单.json
  原始文件/<asset-id>/<original-file-name>
  实验记录/
  分析结果/<asset-id>/<original-file-name>
  导出/<asset-id>/<original-file-name>
```

Unsafe filename characters are replaced for the physical copy; the original
display name remains in the Vault record and project manifest. Asset ID folders
keep duplicate source filenames from overwriting each other. Only active
AssetLinks to a project's experiments, runs, steps, samples, measurements,
calculations, or analyses and their derived-asset descendants are included.
Soft-deleted Assets remain in the manifest as soft-deleted records; existing
browse copies are not automatically removed. If an AssetLink is removed, the
old copy remains on disk and its manifest state becomes `unlinked_retained`; the
project dialog counts it separately from current copies.

The directory contains independent files copied from the Vault's immutable CAS
through a leased read snapshot. Every newly written copy is fully SHA-256
verified. When a known copy's hash changes, Lab Workspace preserves it and
reports the conflict. A missing copy can be regenerated from the CAS. A file
already present at an untracked destination is never adopted, even if its hash
matches; previously managed copies are checked against the CAS file identity to
reject hard links before they are accepted. Unknown or mismatched files are
never overwritten. The project manifest has its own recorded hash and is
likewise preserved when externally changed.

Changing the configured root only changes the active path. It never moves the
Vault, database, or CAS and never removes the old directory. The user can run
“生成／更新目录” to copy project Assets to the newly selected root. Path checks
reject traversal, roots that overlap the Vault or a previously recorded project
root, and symbolic links inside the generated tree.

Absolute roots and copy state are stored in a device-bound local configuration
table, not on synchronized Project records or mutation events. A restored
database on a different device does not activate the previous device's path;
that device starts with its own Documents default and can generate its own
copies. The external directory is not a Vault CAS backup or sync destination.
Back up the directory separately if those convenience copies matter, or
regenerate them from Vault Assets after recovery. The Vault database continues
to use the SQLite Online Backup API and the CAS remains the authoritative
source.

Windows supports directory selection and opening the generated root in File
Explorer. Android and iOS use the app-private Documents directory; this UI does
not provide arbitrary external folder selection or promise that the directory
appears in the system Files app. Platform-granted locations should only be used
when the host platform gives the app access to them.

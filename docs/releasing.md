# Release checklist

1. Run `pwsh -NoProfile -File build/Test-Repository.ps1` from a clean branch.
2. Regenerate `Install-Heresay.vbs` from the exact commit being released.
3. Merge the release commit, then create the version tag on that merge commit.
4. Upload `Install-Heresay.vbs` and every dependency whose manifest URL points at
   this release. Dependencies are installer inputs, not alternative installers;
   users still download only `Install-Heresay.vbs`.
5. Download the published asset again and compute its SHA256 with:

   ```powershell
   Get-FileHash .\Install-Heresay.vbs -Algorithm SHA256
   ```

6. Add the checksum and a tag-pinned source link to the release notes.
7. Download every uploaded asset and compare its SHA256 with the local release file
   or the pinned download manifest before publishing the draft.
8. Confirm the release tag, generated source archives, and installer payload all
   contain the intended commit's files before announcing the release.

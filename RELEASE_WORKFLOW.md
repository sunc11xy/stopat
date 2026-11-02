# Releasing stopat on GitHub

stopat is distributed as an unsigned DMG attached to GitHub Releases. Do not commit DMGs to the repository.

## Create a release

1. Update the app version in Xcode if needed.
2. From the project directory, run:

   ```bash
   chmod +x scripts/create_dmg.sh
   ./scripts/create_dmg.sh
   ```

3. The script builds a release app and creates `release/stopat-v<version>.dmg`.
4. On GitHub, open **Releases** and choose **Create a new release**.
5. Create a matching `v<version>` tag, add release notes, and upload the DMG as a release asset.
6. Publish the release.

## What users will see

Because the app is not signed with a Developer ID or notarized, macOS will initially report that it cannot verify the developer. The README explains the one-time workaround:

1. Dismiss the warning.
2. Open **System Settings → Privacy & Security**.
3. Click **Open Anyway** next to the stopat warning.
4. Confirm the launch, then grant camera access.

This is expected for an unsigned GitHub release. Users should download the DMG only from this repository's GitHub Releases page.

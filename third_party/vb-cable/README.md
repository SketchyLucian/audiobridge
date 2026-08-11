# VB-CABLE redistribution

AudioBridge includes the unchanged `VBCABLE_Driver_Pack45.zip` vendor package
to offer an optional virtual microphone installation after the Windows app is
installed.

- Origin: https://vb-cable.com
- Licensing: https://vb-audio.com/Services/licensing.htm
- Vendor package: `VBCABLE_Driver_Pack45.zip` (October 2024)
- SHA-256: `B950E39F01AF1D04EA623C8F6D8EB9B6EA5C477C637295FABF20631C85116BFB`

VB-CABLE is third-party donationware from VB-Audio Software. AudioBridge must
keep the vendor identity, origin, donationware notice, and licensing link
visible to end users. Do not modify the vendor ZIP.

When updating the package:

1. Download it from the official VB-CABLE site.
2. Inspect the archive paths before extraction.
3. Verify the setup executable's Authenticode signature and the Microsoft
   hardware compatibility signature on the driver catalog.
4. Update the pinned SHA-256 and signer thumbprint in
   `scripts/setup_windows_virtual_mic.ps1` and
   `scripts/package_windows_msi.ps1`.
5. Rebuild the Windows app and verify the copied package has the same hash.

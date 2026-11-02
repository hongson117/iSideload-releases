# TVSideload changes to isideload 0.4.6 (MIT)

Upstream: https://github.com/nab138/isideload — unmodified 0.4.6 plus
`../../patches/isideload-tvos.patch`:

- `DeveloperDeviceType::Tvos` uses the `ios/` developer-services path (Apple has no `tvos/`).
- `add_platform_params` adds `DTDK_Platform=tvos` and `subPlatform=tvOS` to
  `addDevice` and `downloadTeamProvisioningProfile`.
- `Sideloader::set_device_type` selects the platform used for profiles.
- `install_app_rsd_mode(.., upgrade)` uses installation_proxy `Upgrade` (keeps app data).
- iSideload: signing is idempotent for an existing team suffix; `set_preserve_bundle_id(true)` preserves the installed identity for self refresh.

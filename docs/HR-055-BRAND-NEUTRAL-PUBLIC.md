# HR-055: Brand-neutral public build and listing

On October 30, 2026, App Review rejected public 1.0 (9) under Guideline 5.2.1. The app "includes content or features from Samsung, or is marketed to control external hardware from Samsung, without the necessary authorization." Apple offered two routes: provide authorization, or remove the third-party content from the app and its metadata. On November 1, Leon chose removal. The public build still controls the same TVs through the same reviewed local protocol. Only presentation changes.

## What changed

**Public build: the interface names no manufacturer**
- `TVBrand.presentedName` is `nil`. The default TV name is "My TV". Detail and accessibility text show only the model, and Edit TV hides the Brand row.
- The manual-setup brand picker is hidden whenever only one brand is enabled.
- The following are generic:
  - Help pairing guidance, setup guidance and the search details header
  - the demo footnote
  - power help and failure text
  - device-information errors
  - the app-list footnote
  - About and the support-report build scope ("App Store")
- The Local Network permission text reads: "Hafa Remote uses your home network to find and control the TVs you choose."
- Discovery-name fallbacks and the simulated setup model no longer contain a brand.

**Internal build:** keeps brand-specific testing copy for Samsung, Sony and Vizio.

**Unchanged, because it is not user-visible:**
- brand identity used for routing, credentials, Keychain services and protocol modules
- the `_samsungmsf._tcp` Bonjour declaration
- source and type names

A TV may still show its own name, such as the name set on the TV. That is the user's device data, not app content.

**Public listing:** the subtitle, keywords, promotional text, description, review notes and TestFlight notes name no manufacturer or TV platform. Compatibility is described by how the TV connects (a local-network remote connection approved on the TV screen).

**Guards**
- Release preflight fails if public metadata or the public permission text names a TV manufacturer or platform.
- Public unit and UI tests assert brand-neutral About, Help, setup and the permission text.

## Known trade-off

Without a brand name, the listing can't say which TVs work. Some people with incompatible TVs may install the app and find nothing. Discovery shows an empty result, and the description says not every TV supports this. Detailed compatibility belongs on the support site. Whether that page can name the tested hardware is Leon's decision, separate from this source change.

## Store screenshots

The current five store images carry Samsung captions and pre-HR-056 interface scenes. They are regenerated in HR-057 from the final candidate interface. Until then they must not be uploaded.

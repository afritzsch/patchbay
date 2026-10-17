# 9. App Intents, Shortcuts, Spotlight

## Goal

Expose Patchbay's actions to the system: Spotlight ("New Claude session in …"), the Shortcuts app (build your own
automations, e.g. "when I arrive at work, open sessions for my three projects"), and Siri.

## Do a spike first: can `build.sh` produce this at all?

App Intents are discovered from a metadata bundle (`Metadata.appintents`) that **Xcode's build** extracts from the
code (`appintentsmetadataprocessor`). Patchbay builds with SwiftPM and a hand-made bundle, so that step does not
happen automatically. Before designing anything:

1. Write one trivial intent (`OpenPatchbayIntent`) in the target.
2. Try to run the metadata processor by hand in `build.sh` (`xcrun appintentsmetadataprocessor`, on the build
   products and the SDK), put the result in `Contents/Resources/Metadata.appintents`.
3. Check that the action appears in Shortcuts (search "Patchbay") for the installed copy.

If that fails after an afternoon, stop; this is a case for moving to an Xcode project (which also unblocks
[widgets](10-widgets.md)), not for hacking the build further. Record the outcome here.

## Intents, if the spike works

| Intent | Parameters | Notes |
|---|---|---|
| New Session | folder, agent | opens the sheet prefilled, like [plan 3](03-url-scheme-and-finder.md); does not start anything |
| Show Session | session (entity) | selects it and activates the app |
| List Sessions needing attention | none | returns names and status; good for Shortcuts text output |
| Send Prompt | session, text | **only** with a confirmation (`requestConfirmation`) and only to a session at `agentReady` |

- `SessionEntity: AppEntity` with an `EntityQuery` reading `AppDelegate.shared.store.sessions` on the main actor.
  Sessions are runtime objects, so entities hold the id and look the session up when run.
- Intents run inside the app process (declare `openAppWhenRun` for those that show UI), so they can reach the store
  directly.
- Same trust rule as plan 3 and the folder README: Shortcuts and Siri are outside input. Starting an agent with a
  prompt, or typing into a terminal, needs the confirmation step.
- `AppShortcutsProvider` gives Spotlight/Siri phrases without user setup ("New session in Patchbay").

## Files

| File | Change |
|---|---|
| `build.sh` | metadata step (spike) |
| new `Intents.swift` | intents, entity, shortcuts provider |

## Testing

Shortcuts app on the installed copy. The test copy has a different bundle ID, so it appears as a separate app in
Shortcuts; test there first.

## Swift to learn

- Protocols with associated types (`AppEntity`, `EntityQuery`) and macros-free declarative APIs.
- `@Parameter` property wrappers.

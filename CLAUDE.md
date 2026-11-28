# Loaf Chat

## Design rules

### Types

- **Errors are rich, everywhere.** Every outcome a caller would handle differently is its own variant: a typed enum, never a string to parse. Whatever has no variant of its own still arrives whole (code and text), so nothing is lost.
- **Bad states are unrepresentable.** Convert values into types that can only hold valid states, rather than checking flags or options at each use.
- **Types construct themselves.** A type builds itself from its inputs (`new`, `from_*`, `TryFrom`) rather than being assembled field by field by its callers.
- **Conversions go through `From`.** Mapping one type into another (an SDK error into a core error, a port error into a sign-in error) is a `From`/`TryFrom` impl, so `?` and `.into()` do the work.

### Layers

- **Core** (`loaf-core`) holds the interfaces that report state and talk to Matrix. Its API is rich, so the UIs can build custom features on it without re-deriving Matrix rules.
- **Apps** render the UI and own UI state: debouncing, countdowns, navigation, what each screen shows.

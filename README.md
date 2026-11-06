# Forever Character Export

One-click export of your character as readable plain text, for **WoW Forever 1.60.1 (build 70790)**.

Open it with `/fce` or the minimap button to get a full snapshot of your character.

## What gets exported

Character info, equipped gear, bags and bank, quests, talents and spells, professions and skills, pet and pet action bar, action bars, reputations, currencies, active auras, known flight paths, and installed addons.

## Usage

- `/fce` or minimap button (left click): full export
- Minimap button (right click): diagnostic report

Some data (for example the bank) can only be read while the relevant window is open.

## Install

Copy the `addon/ForeverCharacterExport` folder to `Interface/AddOns/`.

## Development

`python dev/check.py` runs Lua 5.1 syntax checks, luacheck and mocked tests. It is not an in-game test.

## License

MIT. See [LICENSE](LICENSE).

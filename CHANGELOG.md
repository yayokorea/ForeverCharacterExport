# Changelog

## 0.3.0

- Removed the build check and `/fce force`. The export now always runs, whatever the game build is, so a client update no longer blocks it. The real build number is still printed in the report header.
- Removed the fixed read limits (auras, addons, currencies, reputations, quest log, quest titles, skills, pet spells, stable slots, talent trees and nodes, spellbook, spell schools, bank tabs, bag slots) and the item-list truncation in the bag and bank output. Everything the game returns is now read and printed.
- Auras are read until the game reports the end of the list.

## 0.2.0

- Initial release.

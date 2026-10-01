# Third-party notices

## Mole

Nori is inspired by and includes source code derived from Mole:

- Project: https://github.com/tw93/Mole
- Vendored revision: `b5c6eccb24f4727da850a1a454aa0df45bb51216`
- License: GNU General Public License v3.0
- License text: [`vendor/mole/LICENSE`](vendor/mole/LICENSE)

The vendored source is kept in `vendor/mole/`. Local `bridge/app_*.sh` files
are Nori integration code and replace same-named GUI bridge resources at
build time. Only the audited helper libraries needed by optional specialty
bridges are packaged; Nori's clean, analyze, uninstall, optimize and
status paths run through its native Swift services.

Nori is distributed under the GNU General Public License v3.0. The complete
license is included in [`LICENSE`](LICENSE), and Mole's original copyright
and license notices remain in the vendored source.

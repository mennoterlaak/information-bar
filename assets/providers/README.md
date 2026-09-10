# Provider artwork

Retrieved 9 September 2026. These marks identify the connected services; Information Bar is an independent app. Trademarks belong to their respective owners. SVG geometry is preserved and rendered as native macOS template images, adapting to the menu bar appearance. The ChatGPT icon uses OpenAI’s Blossom. Its transparent outer canvas is trimmed to the supplied artwork bounds for menu bar sizing; the paths are unchanged. The internal filename remains `codex.svg` to preserve existing preferences and account routing.

| Asset | Source |
| --- | --- |
| `codex.svg` (ChatGPT) | [Official OpenAI SVG](https://github.com/openai/openai-agents-python/blob/main/docs/assets/logo.svg), [original SVG](https://raw.githubusercontent.com/openai/openai-agents-python/main/docs/assets/logo.svg), [repository license](https://github.com/openai/openai-agents-python/blob/main/LICENSE), and [OpenAI brand guidelines](https://openai.com/brand/). |
| `claude.svg` | [Simple Icons v16 Claude](https://cdn.jsdelivr.net/npm/simple-icons@16.0.0/icons/claude.svg), [CC0 license](https://github.com/simple-icons/simple-icons/blob/16.0.0/LICENSE.md). Claude's distinctive starburst. |
| `cursor.svg` | [Cursor official brand assets](https://cursor.com/brand), `General Logos/Cube/SVG/CUBE_2D_LIGHT.svg` from the [official archive](https://ptht05hbb1ssoooe.public.blob.vercel-storage.com/assets/brand/cursor-brand-assets.zip). |
| `vast.svg` | [Vast.ai official documentation repository](https://github.com/vast-ai/docs/blob/main/logo/light.svg), [original SVG](https://raw.githubusercontent.com/vast-ai/docs/main/logo/light.svg). |

Configuration interaction reference: [iStat Menus 7 welcome guide](https://register.bjango.com/help/istatmenus7/welcome/): independent menu items, category sidebar, per-item switch and display configuration, global appearance, and Command-drag ordering. No iStat artwork or code is bundled.

## App icon

`assets/app-icon/AppIcon.icon` is an Icon Composer package: a gauge-ring glyph on a blue automatic gradient with a neutral shadow and translucency. `scripts/build-app.sh` compiles it with the asset compiler into `Assets.car` and `AppIcon.icns`, so macOS renders the Default, Dark, Clear and Tinted styles itself.

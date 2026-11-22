# Zompa brand assets

The [approved brand kit](Zompa-Brand-Kit.pdf) establishes the blue wordmark and the speech bubble with the white Z. The wordmark PNG uses the current lettering on a transparent background. The speech bubble was traced for scalable app and web use.

| Asset | Use |
| --- | --- |
| [wordmark.png](wordmark.png) | Zompa name on Deep Ink |
| [bubble.svg](bubble.svg), [bubble.png](bubble.png) | Standalone mark for the website and in-app motion |
| [icon.svg](icon.svg), [icon.png](icon.png) | Rounded tile for web and distribution materials |
| [Android resources](../../android/app/src/main/res) | Adaptive, themed, legacy launcher, and splash assets |
| [brand.dart](../../lib/brand.dart) | Light and dark UI roles, typography, and launch animation |

Use Deep Ink (`#091A20`) for dark surfaces and labels on Bubble Blue (`#5ECFFE`). Use Wordmark Blue (`#5CB3DB`) for the wordmark on Deep Ink and secondary dark accents. White (`#FEFEFE`) is for the icon's Z and light surfaces. Use Noto Sans Regular for body text and Bold for headings. The bundled fonts are distributed under the SIL Open Font License. See [font notices](FONT-NOTICE.txt).

Let Android apply the launcher mask to the unframed foreground and solid Deep Ink background. The themed launcher uses the same silhouette with the Z cut out. The one-second sequence plays on app startup and is skipped when reduced motion is enabled.

# fundus_design

Nocturne as a Flutter theme: the single place where colours, type sizes,
spacing, radii and elevation live.

Rule for the rest of the workspace: **no hex value and no raw pixel number
outside this package.** Everything is read from `FundusTokens`, available as a
`ThemeExtension` through `Theme.of(context).extension<FundusTokens>()` or the
shorter `context.fundus`.

Derived from `_ds/nocturne-…/styles.css` in the design export. Dark and light
are equal citizens; the ramps are shared and only their roles swap.

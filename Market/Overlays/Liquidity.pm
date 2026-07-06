package Market::Overlays::Liquidity;

# =============================================================================
# Market::Overlays::Liquidity
# =============================================================================
# Package de la especificacion (Tabla 1 / §4.5). Renderizado de liquidez:
# BSL, SSL, EQH/EQL, Sweep/Grab/Run con etiquetas y colores del spec.
# =============================================================================

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use parent 'Market::Overlays::LiquidityOverlay';

1;

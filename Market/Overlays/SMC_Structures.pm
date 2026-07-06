package Market::Overlays::SMC_Structures;

# =============================================================================
# Market::Overlays::SMC_Structures
# =============================================================================
# Package de la especificacion (Tabla 1). Renderizado de estructuras SMC
# (BOS, CHoCH, swings HH/HL/LH/LL) en el Canvas Perl/Tk.
# =============================================================================

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use parent 'Market::Overlays::StructureOverlay';

1;

package Market::Indicators::SMC_Structures;

# =============================================================================
# Market::Indicators::SMC_Structures
# =============================================================================
# Package de la especificacion (Tabla 1). Delega al motor unificado de
# estructura de mercado: BOS, CHoCH, swings y tendencia.
# =============================================================================

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..');

use parent 'Market::Structure::StructureEngine';

1;

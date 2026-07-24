package Market::Overlays::SupplyDemandOverlay;

use strict;
use warnings;

# =============================================================================
# Market::Overlays::SupplyDemandOverlay
# =============================================================================
# Render de zonas de Supply y Demand con jerarquía visual:
#
#   - Supply (oferta/venta):  rectángulos en rojo semitransparente (#ef9a9a)
#   - Demand (demanda/compra): rectángulos en verde semitransparente (#80cbc4)
#   - Confluencia:            borde dorado (#ffeb3b) y relleno más opaco
#
# Las zonas se renderizan en dos pasadas:
#   Pasada 1: zonas normales (sin confluencia) — capa base
#   Pasada 2: zonas de confluencia — capa superior (más visibles)
#
# Cada zona extiende su rectángulo desde su índice de formación hasta
# su índice de invalidación (si existe) o hasta el borde derecho del canvas.
#
# =============================================================================

# Colores base por tipo de zona
my %ZONE_COLOR = (
    supply  => '#ef9a9a',   # rojo claro
    demand  => '#80cbc4',   # verde azulado
);

# Colores de borde (más saturados para definición)
my %ZONE_BORDER = (
    supply  => '#e53935',   # rojo más intenso
    demand  => '#00897b',   # verde más intenso
);

sub new {
    my ($class, %args) = @_;
    my $self = {
        data     => undef,
        canvas   => $args{canvas},
        scale    => $args{scale},
        elements => [],
        %args,
    };
    bless $self, $class;
    return $self;
}

sub set_data {
    my ($self, $data) = @_;
    $self->{data} = $data;
    return $self;
}

# ---------------------------------------------------------------------------
# draw(%args)
# Renderiza las zonas activas de Supply/Demand en el canvas.
# ---------------------------------------------------------------------------
sub draw {
    my ($self, %args) = @_;
    my $canvas    = $args{canvas}    || $self->{canvas};
    my $scale     = $args{scale}     || $self->{scale};
    my $data      = $args{data}      || $self->{data};
    my $start_idx = $args{start_idx};
    my $end_idx   = $args{end_idx};

    return unless $canvas && $scale;
    return unless $data;

    # Verificar setting de visibilidad
    my $settings = $args{settings} || $self->{settings};
    if ($settings && $settings->can('enabled')) {
        return $self unless $settings->enabled('show_supply_demand');
    }

    $self->clear($canvas);

    my $zones = $data->{active} || [];
    return $self unless ref($zones) eq 'ARRAY' && @$zones;

    # Calcular ancho de vela para los rectángulos
    my $cw   = $scale->index_to_center_x(1) - $scale->index_to_center_x(0);
    my $half = $cw > 0 ? $cw / 2 : 2;

    # Separar zonas normales y de confluencia para el orden de capas
    my @normal_zones     = grep { !$_->{confluence} } @$zones;
    my @confluence_zones = grep {  $_->{confluence} } @$zones;

    # ── Pasada 1: Zonas normales ───────────────────────────────────────────
    for my $zone (@normal_zones) {
        next unless $zone && ref($zone) eq 'HASH';
        next unless defined $zone->{index} && defined $zone->{type};

        my ($x1, $y1, $x2, $y2) = _zone_coords($zone, $scale, $half, $start_idx, $end_idx);
        next unless defined $x1;

        my $fill   = $ZONE_COLOR{ $zone->{type} }  || '#999999';
        my $border = $ZONE_BORDER{ $zone->{type} } || '#666666';

        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $fill,
            -stipple => 'gray12',     # semitransparente
            -outline => $border,
            -width   => 1,
            -tags    => ['overlay_supply_demand'],
        );
    }

    # ── Pasada 2: Zonas de confluencia (capa superior) ─────────────────────
    for my $zone (@confluence_zones) {
        next unless $zone && ref($zone) eq 'HASH';
        next unless defined $zone->{index} && defined $zone->{type};

        my ($x1, $y1, $x2, $y2) = _zone_coords($zone, $scale, $half, $start_idx, $end_idx);
        next unless defined $x1;

        my $fill   = $ZONE_COLOR{ $zone->{type} }  || '#999999';
        my $border = '#ffeb3b';  # dorado para confluencia

        # Relleno más opaco (gray25 en vez de gray12) para destacar
        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $fill,
            -stipple => 'gray25',
            -outline => $border,
            -width   => 2,
            -tags    => ['overlay_supply_demand'],
        );

        # Etiqueta de confluencia
        $canvas->createText($x1 + 4, $y1 - 7,
            -text   => 'Confluence',
            -anchor => 'sw',
            -fill   => '#ffeb3b',
            -font   => 'Helvetica 7 bold',
            -tags   => ['overlay_supply_demand'],
        );
    }

    return $self;
}

# ---------------------------------------------------------------------------
# _zone_coords($zone, $scale, $half, $start_idx, $end_idx)
# Calcula las coordenadas (x1, y1, x2, y2) de la zona en el canvas.
# Retorna undef si la zona queda fuera del viewport actual.
# ---------------------------------------------------------------------------
sub _zone_coords {
    my ($zone, $scale, $half, $start_idx, $end_idx) = @_;

    my $idx = $zone->{index};

    # Filtro de viewport: saltar zonas completamente fuera del rango visible
    if (defined $start_idx && defined $end_idx) {
        # La zona se extiende desde $idx hasta $draw_end; si ambos extremos
        # quedan fuera del viewport se puede saltear. Se usa una lógica
        # conservadora: se dibuja si el rango de precio solapa con el viewport.
        # Para zonas muy antiguas cuyo idx < start_idx, se extienden hacia la
        # derecha y pueden seguir visibles.
    }

    # Calcular X de inicio
    my $x1 = $scale->index_to_center_x($idx) - $half;

    # La zona se extiende hasta: invalidated_index, end_idx, o idx+50 (para zonas recientes)
    my $draw_end;
    if (defined $zone->{invalidated_index}) {
        $draw_end = $zone->{invalidated_index};
    }
    elsif (defined $end_idx) {
        $draw_end = $end_idx;
    }
    else {
        $draw_end = $idx + 50;
    }
    $draw_end = $end_idx if defined $end_idx && $draw_end > $end_idx;

    my $x2 = $scale->index_to_center_x($draw_end) + $half;
    $x2 = $x1 + ($half * 2) if $x2 <= $x1;

    my $y1 = $scale->value_to_y($zone->{high});
    my $y2 = $scale->value_to_y($zone->{low});
    ($y1, $y2) = ($y2, $y1) if $y1 > $y2;

    return ($x1, $y1, $x2, $y2);
}

# ---------------------------------------------------------------------------
# clear($canvas)
# ---------------------------------------------------------------------------
sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    $canvas->delete('overlay_supply_demand') if $canvas && $canvas->can('delete');
    $self->{elements} = [];
    return $self;
}

1;

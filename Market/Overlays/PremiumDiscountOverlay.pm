package Market::Overlays::PremiumDiscountOverlay;

# =============================================================================
# Market::Overlays::PremiumDiscountOverlay  — v1.0
# =============================================================================
# Dibuja 3 rectángulos translúcidos con etiquetas:
#   Premium zone     (banda superior, ~95-100% del rango)  — rojo neón
#   Equilibrium zone (banda central, ~47.5-52.5% del rango)— amarillo neón
#   Discount zone    (banda inferior, ~0-5% del rango)      — verde neón
#
# Los rectángulos se extienden horizontalmente desde start_index hasta
# end_index y verticalmente según los precios high/low de cada zona.
#
# Implementación de transparencia: Perl/Tk nativo no soporta alpha en canvas
# rectangles, por lo que se usa stipple 'gray50' para simular semi-opacidad,
# consistente con el patrón ya usado por otros overlays del proyecto.
# =============================================================================

use strict;
use warnings;

# Colores neón SMC Pro
use constant COLOR_PREMIUM     => '#FF4560';  # rojo neón
use constant COLOR_EQUILIBRIUM => '#FFC107';  # ámbar/dorado
use constant COLOR_DISCOUNT    => '#00B746';  # verde neón
use constant OUTLINE_ALPHA     => '';         # sin borde

sub new {
    my ($class, %args) = @_;
    my $self = {
        data     => undef,
        canvas   => $args{canvas},
        scale    => $args{scale},
        settings => $args{settings},
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

sub clear {
    my ($self, $canvas) = @_;
    $canvas ||= $self->{canvas};
    return unless $canvas;
    $canvas->delete('overlay_premium_discount');
}

sub draw {
    my ($self, %args) = @_;
    my $canvas    = $args{canvas}    || $self->{canvas};
    my $scale     = $args{scale}     || $self->{scale};
    my $data      = $args{data}      || $self->{data};
    my $start_idx = $args{start_idx} // 0;
    my $end_idx   = $args{end_idx};

    return unless $canvas && $scale && $data;

    $self->clear($canvas);

    return $self if $self->{settings}
        && $self->{settings}->can('enabled')
        && !$self->{settings}->enabled('show_premium_discount');

    return $self unless ref $data eq 'HASH';

    my $draw_end = defined $end_idx ? $end_idx : undef;

    # Definición de las 3 zonas a dibujar
    my @zones = (
        [ premium     => COLOR_PREMIUM,     'Premium'     ],
        [ equilibrium => COLOR_EQUILIBRIUM, 'Equilibrium' ],
        [ discount    => COLOR_DISCOUNT,    'Discount'    ],
    );

    for my $zone_def (@zones) {
        my ($key, $color, $label) = @$zone_def;
        my $zone = $data->{$key};
        next unless $zone && defined $zone->{high} && defined $zone->{low};
        next unless defined $zone->{start_index};

        my $si = $zone->{start_index};
        my $ei = defined $zone->{end_index} ? $zone->{end_index} : $draw_end;
        $ei //= $si;

        # Recortar al viewport visible
        next if defined $draw_end && $si > $draw_end;
        $ei = $draw_end if defined $draw_end && $ei > $draw_end;

        my $x1 = $scale->index_to_center_x($si);
        my $x2 = $scale->index_to_center_x($ei);
        my $y1 = $scale->value_to_y($zone->{high});
        my $y2 = $scale->value_to_y($zone->{low});

        # Asegurar que x1 < x2, y1 < y2 (Tk requiere coords en orden)
        ($x1, $x2) = ($x2, $x1) if $x1 > $x2;
        ($y1, $y2) = ($y2, $y1) if $y1 > $y2;

        # Rectángulo translúcido (stipple gray50 simula ~50% opacidad)
        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $color,
            -stipple => 'gray50',
            -outline => '',
            -tags    => ['overlay_premium_discount'],
        );

        # Etiqueta centrada en la zona
        my $mid_y = ($y1 + $y2) / 2;
        my $mid_x = ($x1 + $x2) / 2;
        $canvas->createText($mid_x, $mid_y,
            -text => $label,
            -fill => $color,
            -font => 'TkFixedFont',
            -tags => ['overlay_premium_discount'],
        );
    }

    return $self;
}

1;

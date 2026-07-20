package Market::Overlays::MTFLevelsOverlay;

# =============================================================================
# Market::Overlays::MTFLevelsOverlay  — v1.0
# =============================================================================
# Dibuja líneas horizontales High/Low de temporalidades superiores:
#   PDH/PDL  (Previous Daily High/Low)   — azul pastel
#   PWH/PWL  (Previous Weekly High/Low)  — violeta
#   PMH/PML  (Previous Monthly High/Low) — naranja
#
# Las líneas se extienden desde start_index hasta el borde visible actual
# con etiquetas "PDH", "PDL", "PWH", "PWL", "PMH", "PML".
# =============================================================================

use strict;
use warnings;

# Paleta de colores por temporalidad (estilo SMC Pro Neon)
use constant COLOR_DAILY   => '#5C9BD6';  # azul pastel
use constant COLOR_WEEKLY  => '#9B59B6';  # violeta
use constant COLOR_MONTHLY => '#E67E22';  # naranja

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
    $canvas->delete('overlay_mtf_levels');
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

    # Verificar alguna de las tres claves de settings habilitadas
    my $settings = $self->{settings};
    my $any_enabled = !$settings || !$settings->can('enabled') || (
        $settings->enabled('show_daily_levels') ||
        $settings->enabled('show_weekly_levels') ||
        $settings->enabled('show_monthly_levels')
    );
    return $self unless $any_enabled;

    return $self unless ref $data eq 'HASH';

    my $draw_end = defined $end_idx ? $end_idx : undef;

    # ── Definición de temporalidades a dibujar ──────────────────────────
    my @tf_defs = (
        [ daily   => COLOR_DAILY,   'show_daily_levels'   ],
        [ weekly  => COLOR_WEEKLY,  'show_weekly_levels'  ],
        [ monthly => COLOR_MONTHLY, 'show_monthly_levels' ],
    );

    for my $tf_def (@tf_defs) {
        my ($key, $color, $setting_key) = @$tf_def;

        # Verificar si esta TF específica está habilitada
        next if $settings && $settings->can('enabled')
             && !$settings->enabled($setting_key);

        my $tf_data = $data->{$key};
        next unless $tf_data && $tf_data->{enabled};
        next unless defined $tf_data->{high} && defined $tf_data->{low};

        my $si = $tf_data->{start_index} // 0;
        my $ei = defined $tf_data->{end_index} ? $tf_data->{end_index} : $draw_end;
        $ei //= $si;

        # Recortar al viewport
        next if defined $draw_end && $si > $draw_end;
        $ei = $draw_end if defined $draw_end && $ei > $draw_end;

        my $lbl_high = $tf_data->{label_high} // 'HTF High';
        my $lbl_low  = $tf_data->{label_low}  // 'HTF Low';

        # Dibujar High line
        _draw_level_line($canvas, $scale, $si, $ei, $tf_data->{high}, $color, $lbl_high);

        # Dibujar Low line
        _draw_level_line($canvas, $scale, $si, $ei, $tf_data->{low},  $color, $lbl_low);
    }

    return $self;
}

# =============================================================================
# PRIVATE — _draw_level_line
# =============================================================================
sub _draw_level_line {
    my ($canvas, $scale, $start_idx, $end_idx, $price, $color, $label) = @_;

    my $x1 = $scale->index_to_center_x($start_idx);
    my $x2 = $scale->index_to_center_x($end_idx);
    my $y  = $scale->value_to_y($price);

    $canvas->createLine($x1, $y, $x2, $y,
        -fill  => $color,
        -width => 1,
        -dash  => [8, 4],
        -tags  => ['overlay_mtf_levels'],
    );

    # Etiqueta a la derecha de la línea
    $canvas->createText($x2 + 4, $y,
        -text   => $label,
        -fill   => $color,
        -anchor => 'w',
        -font   => 'TkFixedFont',
        -tags   => ['overlay_mtf_levels'],
    );
}

1;

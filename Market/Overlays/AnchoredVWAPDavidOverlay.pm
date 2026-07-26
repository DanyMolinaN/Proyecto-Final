package Market::Overlays::AnchoredVWAPDavidOverlay;

# =============================================================================
# Market::Overlays::AnchoredVWAPDavidOverlay
#
# Portado desde Proyecto_David/Market/Overlays/AnchoredVWAP.pm
# Adaptaciones para Kevin (mismo patron que FibonacciDavidOverlay.pm):
#   - Package renombrado a AnchoredVWAPDavidOverlay.
#   - TAG cambiado a 'david_avwap' / 'david_avwap_labels' (evita colision con
#     AnchoredVWAPOverlay legacy de Kevin, que usa 'avwap_line'/'avwap_band'/
#     'avwap_label').
#   - sub render($canvas, $scale) reemplazada por sub draw(%args).
#   - Campos de Scales.pm corregidos para Kevin:
#       * $scale->{offset}        -> $scale->{start_index}
#       * $scale->{visible_bars}  -> _visible_bars($scale)
#       * $scale->_plot_w         -> $scale->{width} - ($scale->{y_axis_strip_w} // 66)
#       * $scale->_plot_y_top     -> 0 (Kevin no tiene offset vertical de plot)
#   - is_manual_mode() / handle_click($index): mismo contrato que
#     FibonacciDavidOverlay, para que Events.pm rutee el click igual.
# =============================================================================

use strict;
use warnings;

use constant TAG        => 'david_avwap';
use constant TAG_LABELS => 'david_avwap_labels';

use constant {
    C_VWAP     => '#2962ff',
    C_ANCHOR   => '#4f8cff',
    C_BAND1    => '#2962ff',
    C_BAND2    => '#5b8def',
    C_BAND3    => '#8fb3f5',
    VWAP_WIDTH => 2,
};

sub tag        { return TAG; }
sub tag_labels { return TAG_LABELS; }

sub new {
    my ( $class, %args ) = @_;
    my $self = {
        source     => $args{source},   # Market::Indicators::AnchoredVWAPDavid
        show_band1 => $args{show_band1} // 1,
        show_band2 => $args{show_band2} // 1,
        show_band3 => $args{show_band3} // 0,
        # enabled: gestionado por OverlayManager (enable/disable directo)
        enabled    => 0,
    };
    bless $self, $class;
    return $self;
}

sub set_flag {
    my ( $self, $flag, $val ) = @_;
    $self->{$flag} = $val ? 1 : 0;
}

# is_manual_mode: consultado por Events.pm antes de rutear un click de canvas.
sub is_manual_mode {
    my ($self) = @_;
    my $src = $self->{source};
    return 0 unless $src && $src->can('get_mode');
    return $src->get_mode eq 'manual' ? 1 : 0;
}

# handle_click($index): fija el ancla manual en el indicador.
# Events.pm llama este metodo con el indice de vela ya resuelto via
# $scale->x_to_index($x).
sub handle_click {
    my ( $self, $index ) = @_;
    my $src = $self->{source};
    return unless $src;
    return unless $src->can('get_mode') && $src->get_mode eq 'manual';
    $src->set_manual_anchor($index);
}

# ─── Helpers de Scales.pm de Kevin ──────────────────────────────────────────

sub _price_in_range {
    my ( $scale, $price ) = @_;
    return defined($price)
        && $price >= $scale->{min_value}
        && $price <= $scale->{max_value};
}

sub _visible_bars {
    my ($scale) = @_;
    my $cw = $scale->{candle_width} || 8;
    return int( ( $scale->{width} || 800 ) / $cw ) + 1;
}

sub _plot_w {
    my ($scale) = @_;
    return ( $scale->{width} || 800 ) - ( $scale->{y_axis_strip_w} // 66 );
}

# ─── Contrato del render loop de Kevin ──────────────────────────────────────

# draw(%args): llamado por Render.pm::_draw_overlays cuando el overlay esta
# activo (enabled=1). Recibe canvas y scale como named args.
sub draw {
    my ( $self, %args ) = @_;
    my $canvas = $args{canvas};
    my $scale  = $args{scale};
    return unless $canvas && $scale;

    $canvas->delete(TAG);
    $canvas->delete(TAG_LABELS);

    my $src = $self->{source} or return;
    my $series = $src->get_series or return;
    my $points = $series->{points};
    return unless $points && @$points;

    my $off = $scale->{start_index} // 0;
    my $vb  = _visible_bars($scale);
    my $view_from = $off;
    my $view_to   = $off + $vb;

    # --- Punto de ancla ---
    my $anchor_idx   = $series->{anchor_index};
    my $anchor_price = $series->{anchor_price};
    if ( defined $anchor_idx ) {
        my $ax = $scale->index_to_center_x($anchor_idx);
        my $plot_w = _plot_w($scale);
        if ( $ax >= 0 && $ax <= $plot_w ) {
            if ( defined $anchor_price && _price_in_range( $scale, $anchor_price ) ) {
                my $ay = $scale->value_to_y($anchor_price);
                my $r  = 6;
                $canvas->createOval(
                    $ax - $r, $ay - $r, $ax + $r, $ay + $r,
                    -fill => C_ANCHOR, -outline => '#ffffff', -width => 2,
                    -tags => [TAG],
                );
            }
            $canvas->createText(
                $ax + 4, 10,
                -text => 'AVWAP', -anchor => 'w', -fill => C_ANCHOR,
                -font => 'TkDefaultFont 7 bold', -tags => [ TAG, TAG_LABELS ],
            );
        }
    }

    # --- Filtrar puntos visibles (1 de margen a cada lado) ---
    my @visible = grep { $_->{index} >= $view_from - 1 && $_->{index} <= $view_to + 1 } @$points;
    return unless @visible;

    # --- Bandas de desviacion (antes de la linea central, para que quede encima) ---
    $self->_draw_band( $canvas, $scale, \@visible, 'upper1', 'lower1', C_BAND1, 1 )
        if $self->{show_band1};
    $self->_draw_band( $canvas, $scale, \@visible, 'upper2', 'lower2', C_BAND2, 1 )
        if $self->{show_band2};
    $self->_draw_band( $canvas, $scale, \@visible, 'upper3', 'lower3', C_BAND3, 1 )
        if $self->{show_band3};

    # --- Linea central VWAP ---
    $self->_draw_line( $canvas, $scale, \@visible, 'vwap', C_VWAP, VWAP_WIDTH );

    # --- Etiqueta con el ultimo valor ---
    my $last_pt = $visible[-1];
    if ( defined $last_pt->{vwap} && _price_in_range( $scale, $last_pt->{vwap} ) ) {
        my $lx = $scale->index_to_center_x( $last_pt->{index} );
        my $ly = $scale->value_to_y( $last_pt->{vwap} );
        $canvas->createText(
            $lx + 4, $ly,
            -text => sprintf( '%.4f', $last_pt->{vwap} ),
            -anchor => 'w', -fill => C_VWAP,
            -font => 'TkDefaultFont 7 bold', -tags => [ TAG, TAG_LABELS ],
        );
    }
}

# clear($canvas): llamado por _draw_overlays cuando el overlay esta desactivado.
sub clear {
    my ( $self, $canvas ) = @_;
    return unless $canvas;
    $canvas->delete(TAG);
    $canvas->delete(TAG_LABELS);
}

sub _draw_line {
    my ( $self, $canvas, $scale, $points, $field, $color, $width ) = @_;
    my @coords;
    for my $p (@$points) {
        next unless defined $p->{$field};
        push @coords, $scale->index_to_center_x( $p->{index} ), $scale->value_to_y( $p->{$field} );
    }
    return if @coords < 4;
    $canvas->createLine( @coords, -fill => $color, -width => $width, -tags => [TAG] );
}

sub _draw_band {
    my ( $self, $canvas, $scale, $points, $upper_field, $lower_field, $color, $width ) = @_;
    $self->_draw_line( $canvas, $scale, $points, $upper_field, $color, $width );
    $self->_draw_line( $canvas, $scale, $points, $lower_field, $color, $width );
}

1;

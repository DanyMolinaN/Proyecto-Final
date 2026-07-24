package Market::Overlays::TrailingExtremesOverlay;

# =============================================================================
# Market::Overlays::TrailingExtremesOverlay  — v1.0
# =============================================================================
# Dibuja dos líneas horizontales (Strong/Weak High y Strong/Weak Low) con
# etiquetas, extendidas desde el índice donde se alcanzó el extremo hasta el
# borde visible derecho del gráfico.
#
# Paleta de colores (estilo SMC Pro Neon):
#   Strong High / Strong Low : azul neón  (#2196F3)
#   Weak High   / Weak Low   : naranja    (#FF9800)
# =============================================================================

use strict;
use warnings;

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
    $canvas->delete('overlay_trailing_extremes');
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
        && !$self->{settings}->enabled('show_strong_weak_hl');

    my $top    = $data->{top};
    my $bottom = $data->{bottom};
    return $self unless defined $top || defined $bottom;

    my $draw_end = defined $end_idx ? $end_idx : ($scale->can('last_index') ? $scale->last_index() : undef);
    return $self unless defined $draw_end;

    # ── Dibujar extremo superior (top) ───────────────────────────────────
    if ($top && defined $top->{price} && defined $top->{index}) {
        my $label = $top->{label} // 'Strong High';
        my $color = ($label =~ /^Strong/) ? '#2196F3' : '#FF9800';
        my $x1 = $scale->index_to_center_x($top->{index});
        my $x2 = $scale->index_to_center_x($draw_end);
        my $y  = $scale->value_to_y($top->{price});

        $canvas->createLine($x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [6, 3],
            -tags  => ['overlay_trailing_extremes'],
        );
        $canvas->createText($x2 + 4, $y,
            -text   => $label,
            -fill   => $color,
            -anchor => 'w',
            -font   => 'TkFixedFont',
            -tags   => ['overlay_trailing_extremes'],
        );
    }

    # ── Dibujar extremo inferior (bottom) ─────────────────────────────────
    if ($bottom && defined $bottom->{price} && defined $bottom->{index}) {
        my $label = $bottom->{label} // 'Strong Low';
        my $color = ($label =~ /^Strong/) ? '#2196F3' : '#FF9800';
        my $x1 = $scale->index_to_center_x($bottom->{index});
        my $x2 = $scale->index_to_center_x($draw_end);
        my $y  = $scale->value_to_y($bottom->{price});

        $canvas->createLine($x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [6, 3],
            -tags  => ['overlay_trailing_extremes'],
        );
        $canvas->createText($x2 + 4, $y,
            -text   => $label,
            -fill   => $color,
            -anchor => 'w',
            -font   => 'TkFixedFont',
            -tags   => ['overlay_trailing_extremes'],
        );
    }

    return $self;
}

1;

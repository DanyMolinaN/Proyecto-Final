package Market::Panels::GhostTrailPredictionPanel;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        predictor           => $args{predictor},
        market_data         => $args{market_data},
        overlay_settings    => $args{overlay_settings},
        _last_prediction    => undef,
        _last_replay_idx    => undef,
    };
    bless $self, $class;
    return $self;
}

sub set_predictor {
    my ($self, $predictor) = @_;
    $self->{predictor} = $predictor;
}

sub render {
    my ($self, $canvas, $scale, $replay_controller, $analysis_cache) = @_;

    $self->clear($canvas);

    return unless $canvas && $self->{overlay_settings}
        && $self->{overlay_settings}->enabled('show_ghost_prediction_panel');

    return unless $replay_controller && $replay_controller->is_active();
    my $replay_idx = $replay_controller->{current_index};
    return unless defined $replay_idx;

    return unless $analysis_cache && ref $analysis_cache eq 'HASH';
    my $dto = $analysis_cache->{ghost_trails} || $analysis_cache->{dynamic_vwap};
    return unless $dto && ref $dto eq 'HASH';

    my $ghost_trails = $dto->{ghost_trails} || [];
    return unless @$ghost_trails;

    # Buscar ghost_trails cuyo anchor_index sea el indice actual del replay
    my $appearance;
    for my $gt (@$ghost_trails) {
        next unless ref $gt eq 'HASH';
        if (($gt->{anchor_index} // -1) == $replay_idx) {
            $appearance = $gt;
            last;
        }
    }
    return unless $appearance;

    # No recalcular si ya tenemos la prediccion para este mismo indice
    my $cache_key = $replay_idx;
    if (defined $self->{_last_replay_idx} && $self->{_last_replay_idx} == $cache_key
        && $self->{_last_prediction})
    {
        $self->_draw_table($canvas, $scale, $self->{_last_prediction});
        return;
    }

    # Inyectar _ghost_counter para que el predictor acceda a los reales
    $appearance->{_ghost_counter} = $dto->{_ghost_counter};

    my $pred = $self->{predictor}
        ? $self->{predictor}->predict_at_appearance($self->{market_data}, $appearance)
        : undef;
    return unless $pred;

    $self->{_last_prediction}   = $pred;
    $self->{_last_replay_idx}   = $cache_key;

    $self->_draw_table($canvas, $scale, $pred);
}

sub clear {
    my ($self, $canvas) = @_;
    return unless $canvas && $canvas->can('delete');
    $canvas->delete('ghost_prediction_panel');
}

sub _draw_table {
    my ($self, $canvas, $scale, $pred) = @_;

    my $tag   = 'ghost_prediction_panel';
    my $bg    = '#0a0e19';
    my $fg    = '#e0e3ea';
    my $header_fg = '#42a5f5';
    my $ridge_fg  = '#ff9800';
    my $zero_fg   = '#66bb6a';
    my $real_fg   = '#ef5350';

    # Posicion: esquina superior derecha del panel de precios
    my $y0 = ($scale->{y_offset} || 0) + 6;
    my $x0 = ($scale->{width} || 1000) - 310;

    my $col_w  = 62;
    my $row_h  = 18;
    my $header_h = 20;
    my $n_cols = 4;
    my $n_rows = 3;
    my $table_w = $col_w * ($n_cols + 1);
    my $table_h = $header_h + $n_rows * $row_h + 4;

    # Fondo
    $canvas->createRectangle(
        $x0, $y0, $x0 + $table_w, $y0 + $table_h,
        -fill    => $bg,
        -outline => '#363a45',
        -width   => 1,
        -tags    => [$tag],
    );

    my $headers = ['', '3m', '5m', '10m', '15m'];
    my $lh = $y0 + 2;

    # Cabeceras
    for my $ci (0 .. $n_cols) {
        my $lx = $x0 + 2 + $col_w * $ci;
        $canvas->createText(
            $lx + $col_w / 2, $lh + $header_h / 2,
            -text  => $headers->[$ci],
            -fill  => $header_fg,
            -font  => 'Helvetica 8 bold',
            -anchor => 'center',
            -tags  => [$tag],
        );
    }

    # Separador bajo cabecera
    $canvas->createLine(
        $x0, $lh + $header_h, $x0 + $table_w, $lh + $header_h,
        -fill  => '#363a45',
        -width => 1,
        -tags  => [$tag],
    );

    # Filas
    my $rows_data = [
        ['Ridge',  $pred->{ridge}{y_3},  $pred->{ridge}{y_5},
                   $pred->{ridge}{y_10}, $pred->{ridge}{y_15}],
        ['Base 0', $pred->{baseline_zero}{y_3},  $pred->{baseline_zero}{y_5},
                   $pred->{baseline_zero}{y_10}, $pred->{baseline_zero}{y_15}],
    ];

    if ($pred->{real}) {
        push @$rows_data, ['Real',  $pred->{real}{y_3},  $pred->{real}{y_5},
                                    $pred->{real}{y_10}, $pred->{real}{y_15}];
    }

    my @row_colors = ($ridge_fg, $zero_fg, $real_fg);

    for my $ri (0 .. $#$rows_data) {
        my $row = $rows_data->[$ri];
        my $ry  = $lh + $header_h + 2 + $ri * $row_h;
        my $color = $row_colors[$ri] // $fg;

        for my $ci (0 .. $n_cols) {
            my $lx = $x0 + 2 + $col_w * $ci;
            my $text = $row->[$ci];
            if ($ci > 0) {
                $text = defined $text ? sprintf('%.2f', $text) : '--';
            }
            $canvas->createText(
                $lx + $col_w / 2, $ry + $row_h / 2,
                -text  => $text,
                -fill  => $ci == 0 ? $fg : $color,
                -font  => $ci == 0 ? 'Helvetica 8 bold' : 'Helvetica 8',
                -anchor => 'center',
                -tags  => [$tag],
            );
        }
    }
}

1;
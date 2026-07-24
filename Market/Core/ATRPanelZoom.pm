package Market::Core::ATRPanelZoom;

# =============================================================================
# Market::Core::ATRPanelZoom
# Zoom vertical sutil del panel ATR (estilo TradingView).
# Regla fija: el rango SIEMPRE contiene los datos visibles; la linea no desaparece.
#
# FIXES (v2):
#   - FIX-1: apply_drag_at_y usa sensibilidad por-pixel con cap suave extendido
#             (igual que VerticalScaleZoom) para que drags rapidos no queden trabados.
#   - FIX-3: _apply_at_y verifica que data_min/data_max esten definidos ANTES
#             de operar; si no lo estan, retorna 0 sin tocar la escala (safe no-op).
#   - FIX-6: _fit_limits y _expand_to_cover son la unica fuente de limites en
#             apply_wheel_at_y/apply_drag_at_y; los opts de min/max_span_ratio
#             que vienen de ChartEngine._vertical_zoom_opts('atr') se ignoran
#             intencionalmente (ATR tiene su propia logica de limites).
# =============================================================================

use strict;
use warnings;

use constant WHEEL_IN  => 0.94;
use constant WHEEL_OUT => 1.06;

# fit_to_data($scale, $data_min, $data_max) -> $ok
sub fit_to_data {
    my ($scale, $data_min, $data_max) = @_;
    return 0 unless $scale;
    return 0 unless defined $data_min && defined $data_max && $data_max > $data_min;

    my $pad = ($data_max - $data_min) * 0.08;
    $pad = 0.01 if $pad <= 0;
    $scale->set_range($data_min - $pad, $data_max + $pad);
    return 1;
}

# ensure_data_visible($scale, $data_min, $data_max) -> $ok
# Recupera el rango si el zoom manual dejo los datos fuera de escala.
sub ensure_data_visible {
    my ($scale, $data_min, $data_max) = @_;
    return 0 unless $scale;
    return 0 unless defined $data_min && defined $data_max && $data_max > $data_min;

    my ($min, $max) = $scale->get_range();
    return fit_to_data($scale, $data_min, $data_max)
        if $max < $data_min || $min > $data_max;

    my ($lo, $hi) = _fit_limits($data_min, $data_max);
    my ($nmin, $nmax) = _expand_to_cover($min, $max, $data_min, $data_max, $lo, $hi);
    $scale->set_range($nmin, $nmax);
    return 1;
}

# apply_wheel_at_y($scale, $mouse_y, $dir, \%opts) -> $ok
sub apply_wheel_at_y {
    my ($scale, $mouse_y, $dir, $opts) = @_;
    return 0 unless $scale && defined $mouse_y && defined $dir;
    my $factor = $dir < 0 ? WHEEL_IN : WHEEL_OUT;
    return _apply_at_y($scale, $mouse_y, $factor, $opts);
}

# apply_drag_at_y($scale, $mouse_y, $dy, \%opts) -> $ok
sub apply_drag_at_y {
    my ($scale, $mouse_y, $dy, $opts) = @_;
    return 0 unless $scale && defined $mouse_y && defined $dy && $dy != 0;
    $opts ||= {};

    my $ph = $opts->{panel_height} || ($scale->{height} || 110);
    $ph = 110 if $ph <= 0;

    # FIX-1: misma logica que VerticalScaleZoom::apply_drag:
    # - Cap del dy al alto del panel para evitar overflow en exp().
    # - Cap del factor ampliado (0.75..1.25) para no trabar drags rapidos.
    my $sens    = 1.8 / $ph;
    my $dy_safe = $dy;
    $dy_safe =  $ph if $dy_safe >  $ph;
    $dy_safe = -$ph if $dy_safe < -$ph;
    my $factor  = exp($dy_safe * $sens);
    $factor = 0.75 if $factor < 0.75;
    $factor = 1.25 if $factor > 1.25;

    return _apply_at_y($scale, $mouse_y, $factor, $opts);
}

sub _apply_at_y {
    my ($scale, $mouse_y, $factor, $opts) = @_;
    $opts ||= {};

    my $dmin = $opts->{data_min};
    my $dmax = $opts->{data_max};

    # FIX-3: si no hay datos cacheados, safe no-op (la linea ATR nunca desaparece).
    return 0 unless defined $dmin && defined $dmax && $dmax > $dmin;

    ensure_data_visible($scale, $dmin, $dmax);

    my ($min, $max) = $scale->get_range();
    my $range = $max - $min;
    return 0 if $range <= 0;

    my $anchor = $scale->y_to_value($mouse_y);
    $anchor = $min if $anchor < $min;
    $anchor = $max if $anchor > $max;

    my $frac = ($anchor - $min) / $range;
    $frac = 0 if $frac < 0;
    $frac = 1 if $frac > 1;

    my $new_range = $range * $factor;
    my ($rlo, $rhi) = _fit_limits($dmin, $dmax);
    $new_range = $rlo if $new_range < $rlo;
    $new_range = $rhi if $new_range > $rhi;

    my $nmin = $anchor - ($frac * $new_range);
    my $nmax = $nmin + $new_range;
    ($nmin, $nmax) = _expand_to_cover($nmin, $nmax, $dmin, $dmax, $rlo, $rhi);

    $scale->set_range($nmin, $nmax);
    return 1;
}

sub _fit_limits {
    my ($dmin, $dmax) = @_;
    my $span = $dmax - $dmin;
    my $pad  = $span * 0.08;
    $pad = 0.01 if $pad <= 0;
    my $fit  = $span + 2 * $pad;
    my $rlo  = $fit;
    my $rhi  = $fit * 2.5;
    return ($rlo, $rhi);
}

sub _expand_to_cover {
    my ($nmin, $nmax, $dmin, $dmax, $rlo, $rhi) = @_;
    my $pad = ($dmax - $dmin) * 0.06;
    $pad = 0.01 if $pad <= 0;
    my $need_lo = $dmin - $pad;
    my $need_hi = $dmax + $pad;

    my $range = $nmax - $nmin;
    if ($range < $rlo) {
        my $mid = ($nmin + $nmax) / 2;
        $nmin = $mid - $rlo / 2;
        $nmax = $mid + $rlo / 2;
    }
    elsif ($range > $rhi) {
        my $mid = ($nmin + $nmax) / 2;
        $nmin = $mid - $rhi / 2;
        $nmax = $mid + $rhi / 2;
    }

    if ($nmax < $need_hi) {
        my $d = $need_hi - $nmax;
        $nmin += $d;
        $nmax += $d;
    }
    if ($nmin > $need_lo) {
        my $d = $nmin - $need_lo;
        $nmin -= $d;
        $nmax -= $d;
    }

    $range = $nmax - $nmin;
    if ($range < $rlo) {
        my $mid = ($need_lo + $need_hi) / 2;
        $nmin = $mid - $rlo / 2;
        $nmax = $mid + $rlo / 2;
    }

    return ($nmin, $nmax);
}

1;
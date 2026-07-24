package Market::Core::VerticalScaleZoom;

# =============================================================================
# Market::Core::VerticalScaleZoom
# Zoom vertical seguro para la escala Y del precio (estilo TradingView).
# Regla fija: el rango SIEMPRE contiene los datos visibles.
# =============================================================================

use strict;
use warnings;

use constant WHEEL_IN  => 0.94;
use constant WHEEL_OUT => 1.06;

sub fit_to_data {
    my ($scale, $data_min, $data_max, $opts) = @_;
    return 0 unless $scale;
    return 0 unless defined $data_min && defined $data_max && $data_max > $data_min;

    $opts ||= {};
    my $pad = ($data_max - $data_min) * ($opts->{padding_ratio} || 0.06);
    $pad = 0.001 if $pad <= 0;
    $scale->set_range($data_min - $pad, $data_max + $pad);
    return 1;
}

sub ensure_data_visible {
    my ($scale, $data_min, $data_max, $opts) = @_;
    return 0 unless $scale;
    return 0 unless defined $data_min && defined $data_max && $data_max > $data_min;

    my ($min, $max) = $scale->get_range();
    return fit_to_data($scale, $data_min, $data_max, $opts)
        if $max < $data_min || $min > $data_max;

    my ($rlo, $rhi) = _fit_limits($data_min, $data_max);
    my ($nmin, $nmax) = _expand_to_cover($min, $max, $data_min, $data_max, $rlo, $rhi);
    $scale->set_range($nmin, $nmax);
    return 1;
}

sub apply_wheel {
    my ($scale, $mouse_y, $dir, $opts) = @_;
    return 0 unless $scale && defined $mouse_y && defined $dir;
    $opts ||= {};
    _fill_opts_from_scale($scale, $opts);
    my $factor = $dir < 0 ? WHEEL_IN : WHEEL_OUT;
    return _apply_at_y($scale, $mouse_y, $factor, $opts);
}

sub apply_drag {
    my ($scale, $mouse_y, $dy, $opts) = @_;
    return 0 unless $scale && defined $mouse_y && defined $dy && $dy != 0;
    $opts ||= {};

    _fill_opts_from_scale($scale, $opts);

    my $ph = $opts->{panel_height} || ($scale->{height} || 400);
    $ph = 400 if $ph <= 0;

    my $sens   = 2.0 / $ph;
    my $dy_safe = $dy;
    $dy_safe =  $ph if $dy_safe >  $ph;
    $dy_safe = -$ph if $dy_safe < -$ph;
    my $factor = exp($dy_safe * $sens);
    $factor = 0.88 if $factor < 0.88;
    $factor = 1.12 if $factor > 1.12;

    return _apply_at_y($scale, $mouse_y, $factor, $opts);
}

sub _fill_opts_from_scale {
    my ($scale, $opts) = @_;
    return if defined $opts->{data_min} && defined $opts->{data_max};
    return unless $scale;

    my ($cur_min, $cur_max) = $scale->get_range();
    return unless defined $cur_min && defined $cur_max && $cur_max > $cur_min;

    my $margin = ($cur_max - $cur_min) * 0.5;
    $opts->{data_min} = $cur_min - $margin;
    $opts->{data_max} = $cur_max + $margin;
}

sub _apply_at_y {
    my ($scale, $mouse_y, $factor, $opts) = @_;
    $opts ||= {};

    my $dmin = $opts->{data_min};
    my $dmax = $opts->{data_max};
    return 0 unless defined $dmin && defined $dmax && $dmax > $dmin;

    ensure_data_visible($scale, $dmin, $dmax, $opts);

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
    my $pad  = $span * 0.06;
    $pad = 0.001 if $pad <= 0;
    my $fit  = $span + 2 * $pad;
    return ($fit, $fit * 3.0);
}

sub _expand_to_cover {
    my ($nmin, $nmax, $dmin, $dmax, $rlo, $rhi) = @_;
    my $pad = ($dmax - $dmin) * 0.06;
    $pad = 0.001 if $pad <= 0;
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

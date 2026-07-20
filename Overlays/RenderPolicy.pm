package Market::Overlays::RenderPolicy;

use strict;
use warnings;

# Politica compartida para overlays SMC. Prioriza legibilidad: primero decide
# densidad por zoom, luego limita elementos historicos y finalmente resuelve
# colisiones conservando los items de mayor prioridad.

our %PRIORITY = (
    liquidity_run     => 100,
    bos_external      => 95,
    choch_external    => 94,
    external_zigzag   => 92,
    major_bsl         => 90,
    major_ssl         => 90,
    eqh               => 78,
    eql               => 78,
    sweep             => 74,
    grab              => 70,
    hh                => 55,
    hl                => 55,
    lh                => 55,
    ll                => 55,
    internal_zigzag   => 30,
    minor_liquidity   => 26,
    internal_swing    => 24,
    default           => 40,
);

sub priority_for {
    my (%args) = @_;
    my $kind  = lc($args{kind}  // '');
    my $label = lc($args{label} // '');
    my $scope = lc($args{scope} // '');
    my $type  = lc($args{type}  // '');

    return $PRIORITY{liquidity_run} if $type eq 'run' || $kind eq 'run' || $label =~ /\brun\b/;
    return $scope eq 'internal' ? $PRIORITY{default} : $PRIORITY{bos_external}
        if $type eq 'bos' || $label =~ /^bos/i;
    return $scope eq 'internal' ? $PRIORITY{default} : $PRIORITY{choch_external}
        if $type =~ /choch/i || $label =~ /^choch/i;
    return $PRIORITY{external_zigzag} if $kind eq 'external_zigzag';
    return $PRIORITY{internal_zigzag} if $kind eq 'internal_zigzag';
    return $PRIORITY{major_bsl} if $label eq 'bsl' || $type eq 'bsl';
    return $PRIORITY{major_ssl} if $label eq 'ssl' || $type eq 'ssl';
    return $PRIORITY{eqh} if $label eq 'eqh' || $type eq 'eqh';
    return $PRIORITY{eql} if $label eq 'eql' || $type eq 'eql';
    return $PRIORITY{sweep} if $type eq 'sweep' || $label =~ /\bsweep\b/;
    return $PRIORITY{grab} if $type eq 'grab' || $label =~ /\bgrab\b/;
    return $PRIORITY{internal_swing} if $scope eq 'internal' && $kind eq 'swing';
    return $PRIORITY{hh} if $label eq 'hh';
    return $PRIORITY{hl} if $label eq 'hl';
    return $PRIORITY{lh} if $label eq 'lh';
    return $PRIORITY{ll} if $label eq 'll';
    return $PRIORITY{minor_liquidity} if $scope eq 'internal' || $kind eq 'minor_liquidity';
    return $PRIORITY{default};
}

sub zoom_tier {
    my (%args) = @_;
    my $scale = $args{scale};
    my $cw = $args{candle_width};
    $cw = $scale->{candle_width} if !defined $cw && $scale;
    $cw = 8 unless defined $cw && $cw > 0;

    return 'detail' if $cw >= 8;
    return 'normal' if $cw >= 4;
    return 'summary';
}

sub visible_for_zoom {
    my (%args) = @_;
    my $tier     = $args{tier} || 'normal';
    my $kind     = lc($args{kind}  // '');
    my $label    = lc($args{label} // '');
    my $scope    = lc($args{scope} // '');
    my $priority = defined $args{priority}
        ? $args{priority}
        : priority_for(%args);

    return 1 if $args{protected};
    return 1 if $priority >= $PRIORITY{eqh};
    return 0 if $tier eq 'summary' && (
        $scope eq 'internal'
        || $kind eq 'internal_zigzag'
        || $kind eq 'minor_liquidity'
        || $kind eq 'swing'
        || $label =~ /^(hh|hl|lh|ll|sh|sl)$/
    );
    return 0 if $tier eq 'normal' && (
        $kind eq 'internal_zigzag'
        || $kind eq 'minor_liquidity'
        || ($scope eq 'internal' && $kind eq 'swing')
    );
    return 1;
}

sub min_spacing {
    my (%args) = @_;
    my $scale = $args{scale};
    my $cw = $args{candle_width};
    $cw = $scale->{candle_width} if !defined $cw && $scale;
    $cw = 8 unless defined $cw && $cw > 0;

    my $x = int($cw * 3);
    $x = 18 if $x < 18;
    $x = 44 if $x > 44;

    my $y = $args{y_spacing};
    $y = 14 unless defined $y && $y > 0;
    return ($x, $y);
}

sub max_items {
    my (%args) = @_;
    my $tier = $args{tier} || 'normal';
    my $kind = $args{kind} || 'default';

    my %limits = (
        summary => {
            swing => 35, event => 24, liquidity => 30, fvg => 24, default => 30,
        },
        normal => {
            swing => 70, event => 40, liquidity => 55, fvg => 45, default => 55,
        },
        detail => {
            swing => 140, event => 70, liquidity => 90, fvg => 70, default => 90,
        },
    );

    return $limits{$tier}{$kind} || $limits{$tier}{default};
}

sub context_limit {
    my (%args) = @_;
    my $settings = $args{settings};
    my $key = $args{key};
    return undef unless $settings && $key;

    my $values = $settings->can('values') ? $settings->values : undef;
    return undef unless $values && ref($values) eq 'HASH';
    my $value = $values->{$key};
    return undef unless defined $value && $value =~ /^\d+$/ && $value > 0;
    return $value + 0;
}

sub limit_for {
    my (%args) = @_;
    my $configured = context_limit(%args);
    return $configured if defined $configured;
    return max_items(%args);
}

sub detail_allowed {
    my (%args) = @_;
    my $tier = $args{tier} || 'normal';
    my $detail = $args{detail} || 'normal';
    return 1 if $detail eq 'major';
    return 1 if $tier eq 'detail';
    return 1 if $tier eq 'normal' && $detail ne 'minor';
    return 0;
}

sub keep_recent {
    my ($items, %args) = @_;
    return [] unless $items && ref($items) eq 'ARRAY';
    my $max = $args{max};
    return [ @$items ] unless defined $max && $max > 0 && @$items > $max;

    my @sorted = sort { ($b->{index} // 0) <=> ($a->{index} // 0) } @$items;
    @sorted = @sorted[0 .. $max - 1];
    return [ sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @sorted ];
}

sub filter_for_zoom {
    my ($items, %args) = @_;
    return [] unless $items && ref($items) eq 'ARRAY';
    my $tier = $args{tier} || zoom_tier(%args);
    my @kept;
    for my $item (@$items) {
        next unless $item && ref($item) eq 'HASH';
        my $priority = defined $item->{priority}
            ? $item->{priority}
            : priority_for(%$item);
        $item->{priority} = $priority;
        push @kept, $item if visible_for_zoom(%$item, tier => $tier, priority => $priority);
    }
    return \@kept;
}

sub apply_context_limits {
    my ($items, %args) = @_;
    return [] unless $items && ref($items) eq 'ARRAY';

    my %buckets;
    for my $item (@$items) {
        next unless $item && ref($item) eq 'HASH';
        my $bucket = $item->{limit_bucket} || $item->{kind} || 'default';
        push @{ $buckets{$bucket} }, $item;
    }

    my @kept;
    for my $bucket (keys %buckets) {
        my $max = $args{"max_$bucket"};
        $max = limit_for(%args, kind => $bucket, key => "render_max_$bucket")
            unless defined $max;
        push @kept, @{ keep_recent($buckets{$bucket}, max => $max) };
    }
    return [ sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @kept ];
}

sub group_nearby {
    my ($items, %args) = @_;
    return [] unless $items && ref($items) eq 'ARRAY';
    return [ @$items ] unless @$items > 1;

    my ($min_x, $min_y) = min_spacing(%args);
    my $x_radius = defined $args{x_radius} ? $args{x_radius} : int($min_x * 0.75);
    my $y_radius = defined $args{y_radius} ? $args{y_radius} : int($min_y * 0.75);

    my @fixed = grep { $_ && ref($_) eq 'HASH' && $_->{no_group} } @$items;
    my @groupable = grep { $_ && ref($_) eq 'HASH' && !$_->{no_group} } @$items;
    return [ sort { ($a->{index} // 0) <=> ($b->{index} // 0) } (@fixed, @groupable) ]
        unless @groupable > 1;

    my @ordered = sort {
        ($b->{priority} // 0) <=> ($a->{priority} // 0)
            || ($b->{index} // 0) <=> ($a->{index} // 0)
    } @groupable;

    my @groups;
    ITEM:
    for my $item (@ordered) {
        for my $group (@groups) {
            my $head = $group->{head};
            next unless $head;
            next if abs(($item->{x_base} // 0) - ($head->{x_base} // 0)) > $x_radius;
            next if abs(($item->{y_base} // 0) - ($head->{y_base} // 0)) > $y_radius;
            push @{ $group->{members} }, $item;
            next ITEM;
        }
        push @groups, { head => $item, members => [$item] };
    }

    my @result;
    for my $group (@groups) {
        my @members = @{ $group->{members} || [] };
        my ($head) = sort {
            ($b->{protected} ? 1 : 0) <=> ($a->{protected} ? 1 : 0)
                || ($b->{priority} // 0) <=> ($a->{priority} // 0)
                || length($a->{text} // '') <=> length($b->{text} // '')
        } @members;
        next unless $head;
        if (@members > 1) {
            my %seen;
            my @extra = grep {
                my $t = $_->{text} // '';
                $t ne ($head->{text} // '') && !$seen{$t}++;
            } @members;
            $head->{grouped_count} = scalar(@members);
            $head->{grouped_labels} = [ map { $_->{text} } @extra ];
            if (@extra == 1) {
                my $hint = _compact_hint($extra[0]->{text});
                $head->{text} .= '+' . $hint if $hint ne '';
            }
            elsif (@extra > 1 && !$head->{protected}) {
                $head->{text} .= '+' . scalar(@extra);
            }
        }
        push @result, $head;
    }

    return [ sort { ($a->{index} // 0) <=> ($b->{index} // 0) } (@fixed, @result) ];
}

sub _compact_hint {
    my ($text) = @_;
    $text = uc($text // '');
    return 'RUN'   if $text =~ /RUN/;
    return 'SWEEP' if $text =~ /SWEEP/;
    return 'GRAB'  if $text =~ /GRAB/;
    return 'BOS'   if $text =~ /BOS/;
    return 'CHoCH' if $text =~ /CHOCH/i;
    return 'EQH'   if $text =~ /EQH/;
    return 'EQL'   if $text =~ /EQL/;
    return $1 if $text =~ /\b(HH|HL|LH|LL|BSL|SSL)\b/;
    return '';
}

sub resolve_collisions {
    my ($items, %args) = @_;
    return { rendered => 0, hidden => 0, shifted => 0, collisions => 0 }
        unless $items && ref($items) eq 'ARRAY' && @$items;

    my ($min_x, $min_y) = min_spacing(%args);
    $min_x = $args{x_spacing} if defined $args{x_spacing};
    $min_y = $args{y_spacing} if defined $args{y_spacing};

    my @ordered = sort {
        ($b->{priority} // 0) <=> ($a->{priority} // 0)
            || ($b->{index} // 0) <=> ($a->{index} // 0)
    } @$items;

    my @placed;
    my %audit = (rendered => 0, hidden => 0, shifted => 0, collisions => 0);
    for my $item (@ordered) {
        next unless $item && ref($item) eq 'HASH';
        my @tries = $item->{fixed_position} ? (0) : (0, -1, 1, -2, 2, -3, 3);
        my $placed = 0;
        my ($orig_x, $orig_y) = ($item->{x_base}, $item->{y_base});

        for my $step (@tries) {
            $item->{x_base} = $orig_x;
            $item->{y_base} = $orig_y + ($step * $min_y);
            my $box = _bbox($item, $min_x, $min_y);
            my $hit = 0;
            my @keep;
            for my $prev (@placed) {
                if (_intersects($box, $prev->{_bbox})) {
                    if (($item->{fixed_position} || $item->{protected})
                        && (($prev->{priority} // 0) < ($item->{priority} // 0))
                        && !$prev->{fixed_position})
                    {
                        $prev->{hidden} = 1;
                        $audit{hidden}++;
                        next;
                    }
                    $hit = 1;
                }
                push @keep, $prev;
            }
            @placed = @keep if @keep != @placed;
            if (!$hit) {
                $item->{_bbox} = $box;
                $item->{shifted} = 1 if $step != 0;
                $audit{shifted}++ if $step != 0;
                push @placed, $item;
                $audit{rendered}++;
                $placed = 1;
                last;
            }
            $audit{collisions}++;
        }

        next if $placed;
        if ($item->{fixed_position}) {
            $item->{hidden} = 1;
            $audit{hidden}++;
            next;
        }
        if ($item->{protected}) {
            for my $step (4, -4, 5, -5, 6, -6, 7, -7, 8, -8) {
                $item->{x_base} = $orig_x;
                $item->{y_base} = $orig_y + ($step * $min_y);
                my $box = _bbox($item, $min_x, $min_y);
                my $hit = 0;
                for my $prev (@placed) {
                    if (_intersects($box, $prev->{_bbox})) {
                        $hit = 1;
                        last;
                    }
                }
                next if $hit;
                $item->{_bbox} = $box;
                push @placed, $item;
                $audit{rendered}++;
                $audit{shifted}++;
                $placed = 1;
                last;
            }
            if (!$placed) {
                $item->{x_base} = $orig_x;
                $item->{y_base} = $orig_y + (9 * $min_y);
                $item->{_bbox} = _bbox($item, $min_x, $min_y);
                push @placed, $item;
                $audit{rendered}++;
                $audit{shifted}++;
            }
        }
        else {
            $item->{hidden} = 1;
            $audit{hidden}++;
        }
    }

    return \%audit;
}

sub _bbox {
    my ($item, $min_x, $min_y) = @_;
    my $text = defined $item->{text} ? $item->{text} : '';
    my $w = length($text) * 6 + 8;
    $w = $min_x if $w < $min_x;
    my $h = $min_y;
    my $x = $item->{x_base} // 0;
    my $y = $item->{y_base} // 0;
    my $anchor = $item->{anchor} || 'c';
    return [ $x, $y - $h / 2, $x + $w, $y + $h / 2 ] if $anchor eq 'w';
    return [ $x - $w, $y - $h / 2, $x, $y + $h / 2 ] if $anchor eq 'e';
    return [ $x - $w / 2, $y - $h / 2, $x + $w / 2, $y + $h / 2 ];
}

sub _intersects {
    my ($a, $b) = @_;
    return 0 unless $a && $b;
    return 0 if $a->[2] < $b->[0] || $b->[2] < $a->[0];
    return 0 if $a->[3] < $b->[1] || $b->[3] < $a->[1];
    return 1;
}

1;

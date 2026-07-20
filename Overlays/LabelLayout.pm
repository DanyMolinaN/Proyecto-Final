package Market::Overlays::LabelLayout;

use strict;
use warnings;

# resolve_collisions(\@items, %opts) -> ($shift_steps, $collision_count)
# Cada item: { index => N, x_base => X, y_base => Y, priority => P }.
# Menor priority = se coloca primero (swings); mayor = eventos encima.
sub resolve_collisions {
    my ($items, %opts) = @_;
    return (0, 0) unless $items && ref($items) eq 'ARRAY' && @$items;

    my $y_threshold = $opts{y_threshold} // 10;
    my $x_step      = $opts{x_step}      // 12;

    my ($shift_steps, $collision_count) = (0, 0);
    my %groups;
    for my $item (@$items) {
        next unless $item && ref($item) eq 'HASH';
        next unless defined $item->{index};
        push @{ $groups{ $item->{index} } }, $item;
    }

    for my $idx (keys %groups) {
        my @bucket = sort {
            ($a->{priority} // 5) <=> ($b->{priority} // 5)
                || $a->{y_base} <=> $b->{y_base}
        } @{ $groups{$idx} };

        my @placed;
        for my $item (@bucket) {
            my $shift_units = 0;
            for my $prev (@placed) {
                $shift_units++ if abs($item->{y_base} - $prev->{y_base}) < $y_threshold;
            }
            if ($shift_units) {
                $item->{x_base} += $x_step * $shift_units;
                $item->{shifted} = 1;
                $collision_count++;
                $shift_steps += $shift_units;
            }
            push @placed, $item;
        }
    }

    return ($shift_steps, $collision_count);
}

1;

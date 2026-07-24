package Market::Overlays::StructureOverlay;

# =============================================================================
# StructureOverlay::ZigZag
# =============================================================================
# Dibujo de polilineas ZigZag (externo/interno + tentative).
# Continuacion del paquete Market::Overlays::StructureOverlay (split por SRP; sin cambio de API).
# =============================================================================

use strict;
use warnings;

sub _draw_zigzag {
    my ($canvas, $scale, $swings, $tentative, $fill, $width, $dash, $tag) = @_;
    return unless $canvas && $scale && $swings && ref($swings) eq 'ARRAY';

    my @sorted = sort { ($a->{index} // 0) <=> ($b->{index} // 0) }
        grep { $_ && ref $_ eq 'HASH' && defined $_->{index} && defined $_->{price} } @$swings;

    if ($tentative && ref($tentative) eq 'HASH'
        && defined $tentative->{to_index} && defined $tentative->{to_price} )
    {
        my @live;
        if (ref($tentative->{points}) eq 'ARRAY' && @{ $tentative->{points} }) {
            for my $p (@{ $tentative->{points} }) {
                next unless $p && ref $p eq 'HASH';
                next unless defined $p->{index} && defined $p->{price};
                push @live, {
                    index      => $p->{index},
                    price      => $p->{price},
                    _tentative => 1,
                };
            }
        }
        else {
            push @live, {
                index      => $tentative->{to_index},
                price      => $tentative->{to_price},
                _tentative => 1,
            };
        }

        my $last = $sorted[-1];
        if ($last && ($last->{index} // -1) == ( $tentative->{from_index} // -2 )) {
            push @sorted, @live;
        }
        elsif (!@sorted) {
            push @sorted, {
                index => $tentative->{from_index},
                price => $tentative->{from_price},
            }, @live;
        }
        elsif ($last) {
            # Fallback: si from_index no coincide exactamente, extender igual
            # con los puntos vivos posteriores al ultimo swing dibujado.
            my $li = $last->{index} // -1;
            my @after = grep { ($_->{index} // -1) > $li } @live;
            push @sorted, @after if @after;
        }
    }

    return unless @sorted >= 1;

    for my $i (1 .. $#sorted) {
        my $a = $sorted[ $i - 1 ];
        my $b = $sorted[$i];
        next unless defined $a->{price} && defined $b->{price};
        my $x1 = $scale->index_to_center_x( $a->{index} );
        my $y1 = $scale->value_to_y( $a->{price} );
        my $x2 = $scale->index_to_center_x( $b->{index} );
        my $y2 = $scale->value_to_y( $b->{price} );
        my @args = (
            $x1, $y1, $x2, $y2,
            -fill => $fill,
            -width => $width,
            -tags => [$tag],
        );
        # Confirmados: respetan $dash del caller (interno punteado, externo solido).
        # Pierna viva: mismo estilo que el zigzag base para no "cortar" visualmente
        # el External; el interno sigue punteado porque su base ya es dashed.
        if ($b->{_tentative}) {
            push @args, ( -dash => $dash ) if $dash;
        }
        elsif ($dash) {
            push @args, ( -dash => $dash );
        }
        $canvas->createLine(@args);
    }
    return;
}


1;

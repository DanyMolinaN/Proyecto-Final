#!/usr/bin/perl
use strict;
use warnings;
use Time::HiRes qw(time);

my $N = 1497;
my $P = 169;
my $H = 16;
my $T = 4; # 4 targets (horizontes)

print "Creando matrices de prueba N=$N, P=$P, H=$H, T=$T...\n";
# init X (N x P)
my @X;
for my $i (0..$N-1) {
    push @X, [ map { rand() } 1..$P ];
}
# init W1 (P x H)
my @W1;
for my $i (0..$P-1) {
    push @W1, [ map { rand() } 1..$H ];
}
# init B1 (H)
my @B1 = map { rand() } 1..$H;

# init heads W_clf (H x T), W_mag (H x T)
my @W_clf;
my @W_mag;
for my $i (0..$H-1) {
    push @W_clf, [ map { rand() } 1..$T ];
    push @W_mag, [ map { rand() } 1..$T ];
}
my @B_clf = map { rand() } 1..$T;
my @B_mag = map { rand() } 1..$T;

print "Ejecutando Forward + Backward pass...\n";
my $start = time;

# Forward pass
my @Z1; # N x H
my @A1;
for my $i (0..$N-1) {
    for my $j (0..$H-1) {
        my $sum = $B1[$j];
        for my $k (0..$P-1) {
            $sum += $X[$i][$k] * $W1[$k][$j];
        }
        $Z1[$i][$j] = $sum;
        $A1[$i][$j] = $sum > 0 ? $sum : 0; # ReLU
    }
}

my @clf_out;
my @mag_out;
for my $i (0..$N-1) {
    for my $t (0..$T-1) {
        my $c_sum = $B_clf[$t];
        my $m_sum = $B_mag[$t];
        for my $j (0..$H-1) {
            $c_sum += $A1[$i][$j] * $W_clf[$j][$t];
            $m_sum += $A1[$i][$j] * $W_mag[$j][$t];
        }
        # sigmoid clip limits
        $c_sum = -20 if $c_sum < -20;
        $c_sum = 20 if $c_sum > 20;
        $c_sum = 1 / (1 + exp(-$c_sum));
        
        $clf_out[$i][$t] = $c_sum;
        $mag_out[$i][$t] = $m_sum;
    }
}

# Backward pass (mock d_out gradients as random)
my @dW_clf; my @dB_clf;
my @dW_mag; my @dB_mag;
my @dW1; my @dB1;

for my $t (0..$T-1) { $dB_clf[$t] = 0; $dB_mag[$t] = 0; }
for my $j (0..$H-1) { 
    $dB1[$j] = 0;
    for my $t (0..$T-1) { $dW_clf[$j][$t] = 0; $dW_mag[$j][$t] = 0; }
    for my $k (0..$P-1) { $dW1[$k][$j] = 0; }
}

for my $i (0..$N-1) {
    my @dA1;
    for my $j (0..$H-1) { $dA1[$j] = 0; }

    for my $t (0..$T-1) {
        my $d_c = rand() - 0.5; # simulated error gradient
        my $d_m = rand() - 0.5; 

        $dB_clf[$t] += $d_c;
        $dB_mag[$t] += $d_m;

        for my $j (0..$H-1) {
            my $aj = $A1[$i][$j];
            $dW_clf[$j][$t] += $aj * $d_c;
            $dW_mag[$j][$t] += $aj * $d_m;

            $dA1[$j] += $d_c * $W_clf[$j][$t] + $d_m * $W_mag[$j][$t];
        }
    }

    # backprop through ReLU
    for my $j (0..$H-1) {
        my $dz = $Z1[$i][$j] > 0 ? $dA1[$j] : 0;
        $dB1[$j] += $dz;
        for my $k (0..$P-1) {
            $dW1[$k][$j] += $X[$i][$k] * $dz;
        }
    }
}

my $end = time;
printf "\nTiempo de 1 epoca completa (forward+backward): %.4f segundos\n", $end - $start;

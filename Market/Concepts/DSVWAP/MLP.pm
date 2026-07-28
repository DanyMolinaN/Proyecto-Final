package Market::Concepts::DSVWAP::MLP;

use strict;
use warnings;
use Carp qw(croak);

# -----------------------------------------------------------------------------
# new($input_dim, $hidden_dim, $num_targets)
# Inicializa la red neuronal con:
#   Tronco: W1 (P x H) inicializacion He (sqrt(2 / P))
#   Cabezas de Clasificacion: W_clf (H x T) inicializacion Xavier (sqrt(1 / H))
#   Cabezas de Magnitud:      W_mag (H x T) inicializacion Xavier (sqrt(1 / H))
# -----------------------------------------------------------------------------
sub new {
    my ($class, $input_dim, $hidden_dim, $num_targets) = @_;
    
    my $self = {
        P => $input_dim,
        H => $hidden_dim,
        T => $num_targets,
        
        W1 => [], B1 => [],
        W_clf => [], B_clf => [],
        W_mag => [], B_mag => [],
        
        # Momentum buffers
        vW1 => [], vB1 => [],
        vW_clf => [], vB_clf => [],
        vW_mag => [], vB_mag => [],
    };
    
    my $he_std = sqrt(2.0 / $input_dim);
    my $xavier_std = sqrt(1.0 / $hidden_dim);
    
    # Inicializar tronco (He)
    for my $i (0 .. $input_dim - 1) {
        $self->{W1}[$i] = [];
        $self->{vW1}[$i] = [];
        for my $j (0 .. $hidden_dim - 1) {
            $self->{W1}[$i][$j] = _randn() * $he_std;
            $self->{vW1}[$i][$j] = 0;
        }
    }
    for my $j (0 .. $hidden_dim - 1) {
        $self->{B1}[$j] = 0;
        $self->{vB1}[$j] = 0;
    }
    
    # Inicializar cabezas (Xavier)
    for my $j (0 .. $hidden_dim - 1) {
        $self->{W_clf}[$j] = [];
        $self->{W_mag}[$j] = [];
        $self->{vW_clf}[$j] = [];
        $self->{vW_mag}[$j] = [];
        for my $t (0 .. $num_targets - 1) {
            $self->{W_clf}[$j][$t] = _randn() * $xavier_std;
            $self->{W_mag}[$j][$t] = _randn() * $xavier_std;
            $self->{vW_clf}[$j][$t] = 0;
            $self->{vW_mag}[$j][$t] = 0;
        }
    }
    for my $t (0 .. $num_targets - 1) {
        $self->{B_clf}[$t] = 0;
        $self->{B_mag}[$t] = 0;
        $self->{vB_clf}[$t] = 0;
        $self->{vB_mag}[$t] = 0;
    }
    
    bless $self, $class;
    return $self;
}

sub _randn {
    my ($u1, $u2) = (rand(), rand());
    $u1 = 1e-7 if $u1 < 1e-7;
    return sqrt(-2.0 * log($u1)) * cos(6.28318530718 * $u2);
}

# -----------------------------------------------------------------------------
# forward($X)
# X: [N x P] array de arrays.
# Retorna hash con predicciones (clf_out, mag_out) y caches (Z1, A1).
# -----------------------------------------------------------------------------
sub forward {
    my ($self, $X) = @_;
    my $N = scalar @$X;
    my $P = $self->{P};
    my $H = $self->{H};
    my $T = $self->{T};
    
    my (@Z1, @A1, @clf_out, @mag_out);
    
    for my $i (0 .. $N - 1) {
        my $row = $X->[$i];
        
        # Tronco
        for my $j (0 .. $H - 1) {
            my $sum = $self->{B1}[$j];
            for my $k (0 .. $P - 1) {
                $sum += $row->[$k] * $self->{W1}[$k][$j];
            }
            $Z1[$i][$j] = $sum;
            $A1[$i][$j] = $sum > 0 ? $sum : 0; # ReLU
        }
        
        # Cabezas
        for my $t (0 .. $T - 1) {
            my $c_sum = $self->{B_clf}[$t];
            my $m_sum = $self->{B_mag}[$t];
            for my $j (0 .. $H - 1) {
                my $aj = $A1[$i][$j];
                $c_sum += $aj * $self->{W_clf}[$j][$t];
                $m_sum += $aj * $self->{W_mag}[$j][$t];
            }
            
            # Sigmoid (con clip)
            $c_sum = -20 if $c_sum < -20;
            $c_sum = 20 if $c_sum > 20;
            my $prob = 1.0 / (1.0 + exp(-$c_sum));
            
            $clf_out[$i][$t] = $prob;
            $mag_out[$i][$t] = $m_sum;
        }
    }
    
    return {
        Z1 => \@Z1,
        A1 => \@A1,
        clf_out => \@clf_out,
        mag_out => \@mag_out
    };
}

# -----------------------------------------------------------------------------
# compute_loss_and_gradients($X, $Y_clf, $Y_mag, $fwd, $class_weights, $l2_reg)
# Calcula perdida ponderada BCE y MSE (solo en positivos) y gradientes.
# -----------------------------------------------------------------------------
sub compute_loss_and_gradients {
    my ($self, $X, $Y_clf, $Y_mag, $fwd, $class_weights, $l2_reg) = @_;
    my $N = scalar @$X;
    my $P = $self->{P};
    my $H = $self->{H};
    my $T = $self->{T};
    
    my $clf_out = $fwd->{clf_out};
    my $mag_out = $fwd->{mag_out};
    my $A1 = $fwd->{A1};
    my $Z1 = $fwd->{Z1};
    
    my $total_loss = 0;
    
    # Init gradients
    my (@dW1, @dB1, @dW_clf, @dB_clf, @dW_mag, @dB_mag);
    for my $t (0 .. $T - 1) { $dB_clf[$t] = 0; $dB_mag[$t] = 0; }
    for my $j (0 .. $H - 1) {
        $dB1[$j] = 0;
        for my $t (0 .. $T - 1) { $dW_clf[$j][$t] = 0; $dW_mag[$j][$t] = 0; }
        for my $k (0 .. $P - 1) { $dW1[$k][$j] = 0; }
    }
    
    # Backprop
    for my $i (0 .. $N - 1) {
        my @dA1;
        for my $j (0 .. $H - 1) { $dA1[$j] = 0; }
        
        for my $t (0 .. $T - 1) {
            my $y_c = $Y_clf->[$i][$t];
            my $y_m = $Y_mag->[$i][$t];
            
            my $p_c = $clf_out->[$i][$t];
            my $p_m = $mag_out->[$i][$t];
            
            my $w_c = $class_weights->[$t];
            
            # BCE Loss
            my $p_clip = $p_c;
            $p_clip = 1e-7 if $p_clip < 1e-7;
            $p_clip = 1 - 1e-7 if $p_clip > 1 - 1e-7;
            
            if ($y_c == 1) {
                $total_loss -= $w_c * log($p_clip) / $N;
            } else {
                $total_loss -= log(1 - $p_clip) / $N;
            }
            
            # Gradients for classification (BCE + Sigmoid shortcut)
            # dx = p - y, but weighted for positives
            my $d_c;
            if ($y_c == 1) {
                $d_c = $w_c * ($p_c - 1);
            } else {
                $d_c = $p_c;
            }
            $d_c /= $N;
            
            # MSE Loss and Gradient (ONLY if y_c == 1)
            my $d_m = 0;
            if ($y_c == 1) {
                my $err = $p_m - $y_m;
                $total_loss += ($err * $err) / $N;
                $d_m = 2.0 * $err / $N;
            }
            
            $dB_clf[$t] += $d_c;
            $dB_mag[$t] += $d_m;
            
            for my $j (0 .. $H - 1) {
                my $aj = $A1->[$i][$j];
                $dW_clf[$j][$t] += $aj * $d_c;
                $dW_mag[$j][$t] += $aj * $d_m;
                
                $dA1[$j] += $d_c * $self->{W_clf}[$j][$t] + $d_m * $self->{W_mag}[$j][$t];
            }
        }
        
        # ReLU and Trunk backward
        for my $j (0 .. $H - 1) {
            my $dz = $Z1->[$i][$j] > 0 ? $dA1[$j] : 0;
            $dB1[$j] += $dz;
            for my $k (0 .. $P - 1) {
                $dW1[$k][$j] += $X->[$i][$k] * $dz;
            }
        }
    }
    
    # L2 Regularization
    if ($l2_reg > 0) {
        for my $k (0 .. $P - 1) {
            for my $j (0 .. $H - 1) {
                my $w = $self->{W1}[$k][$j];
                $total_loss += 0.5 * $l2_reg * $w * $w;
                $dW1[$k][$j] += $l2_reg * $w;
            }
        }
        for my $j (0 .. $H - 1) {
            for my $t (0 .. $T - 1) {
                my $wc = $self->{W_clf}[$j][$t];
                $total_loss += 0.5 * $l2_reg * $wc * $wc;
                $dW_clf[$j][$t] += $l2_reg * $wc;
                
                my $wm = $self->{W_mag}[$j][$t];
                $total_loss += 0.5 * $l2_reg * $wm * $wm;
                $dW_mag[$j][$t] += $l2_reg * $wm;
            }
        }
    }
    
    return {
        loss => $total_loss,
        dW1 => \@dW1, dB1 => \@dB1,
        dW_clf => \@dW_clf, dB_clf => \@dB_clf,
        dW_mag => \@dW_mag, dB_mag => \@dB_mag
    };
}

# -----------------------------------------------------------------------------
# apply_gradients($grads, $lr, $momentum)
# -----------------------------------------------------------------------------
sub apply_gradients {
    my ($self, $grads, $lr, $momentum) = @_;
    my $P = $self->{P};
    my $H = $self->{H};
    my $T = $self->{T};
    
    for my $j (0 .. $H - 1) {
        # B1
        $self->{vB1}[$j] = $momentum * $self->{vB1}[$j] - $lr * $grads->{dB1}[$j];
        $self->{B1}[$j] += $self->{vB1}[$j];
        
        # W1
        for my $k (0 .. $P - 1) {
            $self->{vW1}[$k][$j] = $momentum * $self->{vW1}[$k][$j] - $lr * $grads->{dW1}[$k][$j];
            $self->{W1}[$k][$j] += $self->{vW1}[$k][$j];
        }
        
        # Cabezas
        for my $t (0 .. $T - 1) {
            $self->{vW_clf}[$j][$t] = $momentum * $self->{vW_clf}[$j][$t] - $lr * $grads->{dW_clf}[$j][$t];
            $self->{W_clf}[$j][$t] += $self->{vW_clf}[$j][$t];
            
            $self->{vW_mag}[$j][$t] = $momentum * $self->{vW_mag}[$j][$t] - $lr * $grads->{dW_mag}[$j][$t];
            $self->{W_mag}[$j][$t] += $self->{vW_mag}[$j][$t];
        }
    }
    
    for my $t (0 .. $T - 1) {
        $self->{vB_clf}[$t] = $momentum * $self->{vB_clf}[$t] - $lr * $grads->{dB_clf}[$t];
        $self->{B_clf}[$t] += $self->{vB_clf}[$t];
        
        $self->{vB_mag}[$t] = $momentum * $self->{vB_mag}[$t] - $lr * $grads->{dB_mag}[$t];
        $self->{B_mag}[$t] += $self->{vB_mag}[$t];
    }
}

1;

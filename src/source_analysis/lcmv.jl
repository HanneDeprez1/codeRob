"""
    beamformer_lcmv{A <: AbstractFloat}(x::Array{A, 3}, n::Array{A, 3}, H::Array{A, 3}, fs::Real, foi::Real; kwargs...)

Linearly constrained minimum variance (LCMV) beamformer for epoched data

LCMV beamformer returning neural activity index (NAI), source and noise variance (Van Veen et al 1997).
Source space projection is implemented (Sekihara et al 2001).


### Literature

Localization of brain electrical activity via linearly constrained minimum variance spatial filtering
Van Veen, B. D., van Drongelen, W., Yuchtman, M., & Suzuki, A.
Biomedical Engineering, IEEE Transactions on, 44(9):867–880, 1997.

Reconstructing spatio-temporal activities of neural sources using an meg vector beamformer technique
Kensuke Sekihara, Srikantan S Nagarajan, David Poeppel, Alec Marantz, and Yasushi Miyashita.
Biomedical Engineering, IEEE Transactions on, 48(7):760–771, 2001.


### Input

* x = M * T x N matrix = Signal M sample measurements over T trials on N electrodes
* n = M * T x N matrix = Noise  M sample measurements over T trials on N electrodes
* H = L x D x N matrix = Forward head model for L locations on N electrodes in D dimensions
* fs = Sample rate
* foi = Frequency of interest for cross spectral density
* freq_pm = Frequency above and below `foi` to include in csd calculation (1.0)

"""
function beamformer_lcmv{A <: AbstractFloat}(x::Array{A, 3}, n::Array{A, 3}, H::Array{A, 3}, fs::Real, foi::Real;
                         freq_pm::Real = 0.5, kwargs...)

    Logging.debug("Starting LCMV beamforming on epoch data of size $(size(x, 1)) x $(size(x, 2)) x $(size(x, 3)) and $(size(n, 1)) x $(size(n, 2)) x $(size(n, 3))")

    # Constants
    M = size(x, 1)   # Samples
    N = size(x, 3)   # Sensors
    L = size(H, 1)   # Locations
    D = size(H, 2)   # Dimensions

    # Check input
    @assert size(n, 3) == N     # Ensure inputs match
    @assert size(H, 3) == N     # Ensure inputs match
    @assert M > N               # Should have more samples than sensors
    @assert !any(isnan(x))
    @assert !any(isnan(n))
    @assert !any(isnan(H))

    Logging.debug("LCMV epoch beamformer using $M samples on $N sensors for $L sources over $D dimensions")

    C = cross_spectral_density(x, foi - freq_pm, foi + freq_pm, fs)
    Q = cross_spectral_density(n, foi - freq_pm, foi + freq_pm, fs)

    # More (probably unnecessary) checks
    @assert size(C) == size(Q)
    @assert C != Q

    beamformer_lcmv(C, Q, H; kwargs...)
end


function beamformer_lcmv{A <: AbstractFloat}(C::Array{Complex{A}, 2}, Q::Array{Complex{A}, 2}, H::Array{A, 3};
                              subspace::A=0.95, regularisation::A=0.003, progress::Bool=false, kwargs...)

    Logging.debug("Computing LCMV beamformer from CPSD data")

    N = size(C, 1)   # Sensors
    L = size(H, 1)   # Locations

    # Space to save results
    Variance  = Array(Float64, (L, 1))         # Variance
    Noise     = Array(Float64, (L, 1))         # Noise
    NAI       = Array(Float64, (L, 1))         # Neural Activity Index
    Logging.debug("Result variables pre allocated")

    # TODO before or after subspace?
    # Default as suggested in discussion of Sekihara
    if regularisation > 0
        S = svdfact(real(C)).S[1]
        C = C + regularisation * S * eye(C)
        Logging.debug("Regularised signal matrix with lambda = $(S * regularisation)")
        S = svdfact(real(Q)).S[1]
        Q = Q + regularisation * S * eye(Q)
        Logging.debug("Regularised noise matrix with lambda = $(S * regularisation)")
    end

    if subspace > 0

        # Create subspace from singular vectors
        ss, k = retain_svd(real(C), subspace)
        ss = ss'

        Logging.debug("Subspace constructed of $(size(ss, 1)) components constituting $(100*round(k, 5))% of power")

        # Apply subspace to signal and noise
        C = ss * C * ss'
        Q = ss * Q * ss'

        Logging.debug("Subspace projection calculated")

    else
        ss = eye(real(C))
    end

    # Compute inverse outside loop
    invC = pinv(C)
    invQ = pinv(Q)

    Logging.debug("Beamformer scan started")
    if progress; prog = Progress(L, 1, "  LCMV scan... ", 40); end
    for l = 1:L

        H_l = ss * squeeze(H[l,:,:], 1)'

        Variance[l], Noise[l], NAI[l] = beamformer_lcmv(invC, invQ, H_l)

        if progress; next!(prog); end
    end

    Logging.debug("Beamformer scan completed")

    return Variance, Noise, NAI
end


function beamformer_lcmv(invC::Array{Complex{Float64}, 2}, invQ::Array{Complex{Float64}, 2}, H::Array{Float64, 2})

    V_q = trace(pinv(H' * invC * H)[1:3, 1:3])   # Strength of source     Eqn 24: trace(3x3)

    N_q = trace(pinv(H' * invQ * H)[1:3, 1:3])   # Noise strength         Eqn 26: trace(3x3)

    NAI = V_q / N_q                              # Neural activity index  Eqn 27

    return abs(V_q), abs(N_q), abs(NAI)
end


##########################
#
# High level functions
#
##########################

"""
    beamformer_lcmv(s::SSR, n::SSR, l::Leadfield; kwargs...)

Linearly constrained minimum variance (LCMV) beamformer for epoched data.

NAI is ratio between stimulus and control data.


### Input

* s = stimulus condition SSR data with epochs pre calculated
* n = control condition SSR with epochs pre calculated
* l = leadfield information

* foi = frequency of interest for cross power spectral density calculations
* fs = sample rate
* n_epochs = number of epochs to average down to with aim of reducing noise

"""
function beamformer_lcmv(s::SSR, n::SSR, l::Leadfield;
                         foi::Real=modulationrate(s), fs::Real=samplingrate(s), n_epochs::Int=0, kwargs...)

    Logging.info("Performing LCMV beamforming on signal with noise data as reference")

    if !haskey(s.processing, "epochs") || !haskey(n.processing, "epochs")
        Logging.critical("Epochs not calculated")
    end

    if n_epochs > 0
        s.processing["epochs"] = reduce_epochs(s.processing["epochs"], n_epochs)
        n.processing["epochs"] = reduce_epochs(n.processing["epochs"], n_epochs)
    end

    l = match_leadfield(l, s)

    V, N, NAI = beamformer_lcmv(s.processing["epochs"], n.processing["epochs"], l.L, fs, foi; kwargs...)

    VolumeImage(vec(NAI), "NAI", l.x, l.y, l.z, ones(size(vec(NAI))), "LCMV", Dict(), "Talairach")
end

"""   
    IAAFT([x,])

An iteratively adjusted amplitude-adjusted-fourier-transform surrogate[^SchreiberSchmitz1996].

IAAFT surrogate have the same linear correlation, or periodogram, and also 
preserves the amplitude distribution of the original data, but are improved relative 
to AAFT through iterative adjustment.

If the timeseries `x` is provided, fourier transforms are planned, enabling more efficient
use of the same method for many surrogates of a signal with same length and eltype as `x`.

## References

[^SchreiberSchmitz1996]: T. Schreiber; A. Schmitz (1996). "Improved Surrogate Data for Nonlinearity 
    Tests". Phys. Rev. Lett. 77 (4): 635–638. doi:10.1103/PhysRevLett.77.635.
    PMID 10062864. [https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.77.635](https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.77.635)
"""
struct IAAFT{F, I} <: Surrogate
    forward::F
    inverse::I
    n_maxiter::Int
    tol::Real
    n_windows::Int
end

IAAFT(;n_maxiter::Int = 100, tol::Real = 1e-6, n_windows::Int = 75) = 
    RandomFourier(nothing, nothing, n_maxiter, tol, n_windows)

function IAAFT(s::AbstractVector; n_maxiter::Int = 100, tol::Real = 1e-6, n_windows::Int = 75)
    forward = plan_rfft(s)
    inverse = plan_irfft(forward*s, length(s))
    return IAAFT(forward, inverse, n_maxiter, tol, n_windows)
end


function surrogate(s, method::IAAFT) 
    # Coarse-grain the periodograms when comparing them between iterations.
    p = DSP.periodogram(s)
    range = LinRange(0.0, 0.5, method.n_windows)
    power_binned = interp(p.freq, p.power, range)

    # Keep track of difference between periodograms between iterations
    diffs = zeros(Float64, 2)

    # Sorted version of the original time series
    original_sorted = sort(s)

    # Fourier transform of the zero-mean normalized original signal 
    # and its amplitudes
    m = mean(s)
    𝓕 = method.forward*(s .- m)
    r_original = abs.(𝓕)

    # RANK ORDERING.
    # Create some Gaussian noise, and find the indices that sorts it with
    # increasing amplitude. Then sort the original time series according to
    # the indices rendering the Gaussian noise sorted.
    n = length(s)
    g = rand(Normal(), n)
    inds = sortperm(g)
    ts_sorted = s[inds]

    𝓕new = Vector{Complex{Float64}}(undef, length(𝓕))
    𝓕sorted = Vector{Complex{Float64}}(undef, length(𝓕))
    ϕsorted = Vector{Complex{Float64}}(undef, length(𝓕))
    surr = Vector{Float64}(undef, n)
    
    iter = 1
    success = false
    while iter <= method.n_maxiter
        # Take the Fourier transform of `ts_sorted` and get the phase angles of
        # the resulting complex numbers.
        𝓕sorted .= method.forward * ts_sorted
        ϕsorted .= angle.(𝓕sorted)

        # The new spectrum preserves the amplitudes of the Fourier transform of
        # the original time series, but randomises the phases (because the
        # phases are derived from the *randomly sorted* version of the original
        # time series).
        𝓕new .= r_original .* exp.(ϕsorted .* 1im)

        # Now, let the surrogate time series be the values of the original time
        # series, but sorted according to the new spectrum. The shuffled series
        # is generated by taking the inverse Fourier transform of the spectrum
        # consisting of the original amplitudes, but having randomised phases.
        surr .= real.(method.inverse * 𝓕new) # ifft normalises by default

        # map original values onto shuffle
        surr[sortperm(surr)] = original_sorted

        ts_sorted[:] = surr

        # Convergence check on periodogram
        p_surr = DSP.periodogram(surr)
        power_binned_surr = interp(p_surr.freq, p_surr.power, range)

        if iter == 1
            diffs[1] = sum((power_binned[2] .- power_binned_surr[2]).^2) /
                        sum(power_binned[2].^2)
        else
            diffs[2] = sum((power_binned[2] .- power_binned_surr[2]).^2) /
                        sum(power_binned[2].^2)
            abs(diffs[1] - diffs[2]) < method.tol ? break : diffs[1] = copy(diffs[2])
        end

        iter += 1
    end
    surr
end

"""
    iaaft(ts::AbstractArray{T, 1} where T;
            n_maxiter = 200, tol = 1e-6, n_windows = 50)

Generate an iteratively adjusted amplitude adjusted Fourier transform 
(IAAFT)[^SchreiberSchmitz1996] surrogate realization of `ts`.

## Arguments

- **`ts`**: the time series for which to generate an AAFT surrogate realization.

- **`n_maxiter`**: sets the maximum number of iterations to allow before ending
    the algorithm (if convergence is slow).

- **`tol`**: the relative tolerance for deciding if convergence is achieved.

- **`n_window`**: the number is windows used when binning the periodogram (used
    for determining convergence).

## References

[^SchreiberSchmitz1996]: T. Schreiber; A. Schmitz (1996). "Improved Surrogate Data for Nonlinearity 
    Tests". Phys. Rev. Lett. 77 (4): 635–638. doi:10.1103/PhysRevLett.77.635.
    PMID 10062864. [https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.77.635](https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.77.635)
"""
function iaaft(ts::AbstractVector{T} where T;
                n_maxiter::Int = 100, tol::Real = 1e-6, n_windows::Int = 50)
    any(isnan.(ts)) && throw(DomainError(NaN,"The input must not contain NaN values."))

    # Sorted version of the original time series
    original_sorted = sort(ts)

    # Fourier transform and its amplitudes
    original_fft = fft(ts)
    original_fft_amplitudes = abs.(original_fft)

    # RANK ORDERING.
    # Create some Gaussian noise, and find the indices that sorts it with
    # increasing amplitude. Then sort the original time series according to
    # the indices rendering the Gaussian noise sorted.
    n = length(ts)
    g = rand(Normal(), n)
    inds = sortperm(g)
    ts_sorted = ts[inds]

    iter = 1
    success = false

    spectrum = Vector{Complex{Float64}}(undef, n)
    surr = Vector{Float64}(undef, n)

    diffs = zeros(Float64, 2)
    while iter <= n_maxiter
        # Take the Fourier transform of `ts_sorted` and get the phase angles of
        # the resulting complex numbers.
        FT = fft(ts_sorted)
        phase_angles = angle.(FT)

        # The new spectrum preserves the amplitudes of the Fourier transform of
        # the original time series, but randomises the phases (because the
        # phases are derived from the *randomly sorted* version of the original
        # time series).
        spectrum .= original_fft_amplitudes .* exp.(phase_angles .* 1im)

        # Now, let the surrogate time series be the values of the original time
        # series, but sorted according to the new spectrum. The shuffled series
        # is generated by taking the inverse Fourier transform of the spectrum
        # consisting of the original amplitudes, but having randomised phases.
        surr[:] = real(ifft(spectrum)) # ifft normalises by default

        # map original values onto shuffle
        surr[sortperm(surr)] = original_sorted

        ts_sorted[:] = surr

        # Convergence check
        periodogram = DSP.mt_pgram(ts)
        periodogram_surr = DSP.mt_pgram(surr)

        power_binned = interp([x for x in periodogram.freq],
                            periodogram.power,
                            n_windows)

        power_binned_surr = interp([x for x in periodogram_surr.freq],
                            periodogram_surr.power,
                            n_windows)

        if iter == 1
            diffs[1] = sum((power_binned[2] .- power_binned_surr[2]).^2) /
                        sum(power_binned[2].^2)
        else
            diffs[2] = sum((power_binned[2] .- power_binned_surr[2]).^2) /
                        sum(power_binned[2].^2)
            if abs(diffs[1] - diffs[2]) < tol
                break
            end
            diffs[1] = copy(diffs[2])
        end

        iter += 1
    end
    surr
end


"""
    iaaft_iters(ts::AbstractArray{T, 1} where T;
                n_maxiter = 100, tol = 1e-5, n_windows = 50)

Generate an iteratively adjusted amplitude adjusted Fourier transform (IAAFT) [1]
surrogate series for `ts` and return a vector containing the surrogate realizations
from each iteration (ideally, these will be the gradually improving realizations - 
in terms of having better matching periodograms with the periodogram of the original
signal with every iteration). The last vector contains the final surrogate.

# Literature references
1. T. Schreiber; A. Schmitz (1996). "Improved Surrogate Data for Nonlinearity
Tests". Phys. Rev. Lett. 77 (4): 635–638. doi:10.1103/PhysRevLett.77.635. PMID
10062864.
"""
function iaaft_iters(ts::AbstractArray{T, 1} where T;
                        n_maxiter = 100, tol = 1e-5, n_windows = 50)

    # Sorted version of the original time series
    original_sorted = sort(ts)

    # Fourier transform and its amplitudes
    original_fft = fft(ts)
    original_fft_amplitudes = abs.(original_fft)

    # Create some Gaussian noise, and find the indices that sorts it with
    # increasing amplitude. Then sort the original time series according to the
    # indices rendering the Gaussian noise sorted.
    n = length(ts)
    g = rand(Normal(), n)
    inds = sortperm(g)
    ts_sorted = ts[inds]

    iter = 1
    success = false

    spectrum = Vector{Complex{Float64}}(undef, n)
    surr = Vector{Float64}(undef, n)
    surrogates = Vector{Vector{Float64}}(undef, 0)

    diffs = zeros(Float64, 2)
    while iter <= n_maxiter
        # Take the Fourier transform of `ts_sorted` and get the phase angles
        # of the resulting complex numbers.
        ts_sorted_fft = fft(ts_sorted)
        phase_angles = angle.(ts_sorted_fft)

        # The new spectrum preserves the amplitudes of the Fourier transform
        # of the original time series, but randomises the phases (because the
        # phases are derived from the *randomly sorted* version of the original
        # time series).
        spectrum .= original_fft_amplitudes .* exp.(phase_angles .* 1im)

        # Now, let the surrogate time series be the values of the original time
        # series, but sorted according to the new spectrum. The shuffled series
        # is generated by taking the inverse Fourier transform of the spectrum
        # consisting of the original amplitudes, but having randomised phases.
        surr[:] = real(ifft(spectrum)) # ifft normalises by default
        surr[sortperm(surr)] = original_sorted # map original values onto shuffle
        push!(surrogates, surr[:])

        ts_sorted .= surr

        # Convergence check
        periodogram = DSP.mt_pgram(ts)
        periodogram_surr = DSP.mt_pgram(surr)

        power_binned = interp([x for x in periodogram.freq],
                                periodogram.power,
                                n_windows)

        power_binned_surr = interp([x for x in periodogram_surr.freq],
                                    periodogram_surr.power,
                                    n_windows)

        if iter == 1
            diffs[1] = sum((power_binned[2] .- power_binned_surr[2]).^2) /
                        sum(power_binned[2].^2)
        else
            diffs[2] = sum((power_binned[2] .- power_binned_surr[2]).^2) /
                        sum(power_binned[2].^2)

            if abs(diffs[1] - diffs[2]) < tol
                break
            end
            diffs[1] = copy(diffs[2])
        end

        iter += 1
    end
    surrogates
end

export iaaft

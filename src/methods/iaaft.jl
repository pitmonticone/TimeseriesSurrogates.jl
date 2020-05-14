export IAAFT
"""   
    IAAFT(M = 100, tol = 1e-6, W = 75)

An iteratively adjusted amplitude-adjusted-fourier-transform surrogate[^SchreiberSchmitz1996].

IAAFT surrogate have the same linear correlation, or periodogram, and also 
preserves the amplitude distribution of the original data, but are improved relative 
to AAFT through iterative adjustment (which runs for a maximum of `M` steps). 
During the iterative adjustment, the periodograms of the original signal and the 
surrogate are coarse-grained and the powers are averaged over `W` equal-width 
frequency bins. The iteration procedure ends when the relative deviation 
between the periodograms is less than `tol` (or when `M` is reached).

## References

[^SchreiberSchmitz1996]: T. Schreiber; A. Schmitz (1996). "Improved Surrogate Data for Nonlinearity 
    Tests". Phys. Rev. Lett. 77 (4): 635–638. doi:10.1103/PhysRevLett.77.635.
    PMID 10062864. [https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.77.635](https://journals.aps.org/prl/abstract/10.1103/PhysRevLett.77.635)
"""
struct IAAFT <: Surrogate
    M::Int
    tol::Real
    W::Int

    function IAAFT(;M::Int = 100, tol::Real = 1e-6, W::Int = 75)
        new(M, tol, W)
    end
end

Base.show(io::IO, x::IAAFT) = print(io, "IAAFT(M=$(x.M), tol=$(x.tol), W=$(x.W))")

function surrogenerator(x, method::IAAFT)
    # Pre-plan Fourier transforms
    forward = plan_rfft(x)
    inverse = plan_irfft(forward*x, length(x))

    # Pre-compute stuff that can be used for different surrogate realizations
    m = mean(x)
    x_sorted = sort(x)
    𝓕 = forward*(x .- m)
    r_original = abs.(𝓕)

    # Coarse-grain the periodograms when comparing them between iterations.
    px = DSP.periodogram(x)
    range = LinRange(0.0, 0.5, method.W)
    px_binned = interp(px.freq, px.power, range)

    # These are updated during iteration procedure
    𝓕new = Vector{Complex{Float64}}(undef, length(𝓕))
    𝓕sorted = Vector{Complex{Float64}}(undef, length(𝓕))
    ϕsorted = Vector{Complex{Float64}}(undef, length(𝓕))

    init = (forward = forward, inverse = inverse, m = m, 𝓕 = 𝓕, r_original = r_original,
            px_binned = px_binned, range = range, x_sorted = x_sorted,
            𝓕new = 𝓕new, 𝓕sorted =  𝓕sorted, ϕsorted = ϕsorted)

    return SurrogateGenerator(method, x, init)
end

function (sg::SurrogateGenerator{<:IAAFT})()
    init_fields = (:forward, :inverse, :m, :𝓕, :r_original, 
                    :px_binned, :range, 
                    :x_sorted,
                    :𝓕new, :𝓕sorted, :ϕsorted)
    forward, inverse, m, 𝓕, r_original, 
        px_binned, range, 
        x_sorted,
        𝓕new, 𝓕sorted, ϕsorted = getfield.(Ref(sg.init), init_fields)

    x = sg.x
    M = sg.method.M
    tol = sg.method.tol
    
    # Keep track of difference between periodograms between iterations
    diffs = zeros(Float64, 2)

    # RANK ORDERING.
    # Create some Gaussian noise, and find the indices that sorts it with
    # increasing amplitude. Then sort the original time series according to
    # the indices rendering the Gaussian noise sorted.
    n = length(x)
    g = rand(Normal(), n)
    ts_sorted = x[sortperm(g)]

    # The surrogate
    s = Vector{Float64}(undef, n)
    
    iter = 1
    success = false
    while iter <= M
        # Take the Fourier transform of `ts_sorted` and get the phase angles of
        # the resulting complex numbers.
        𝓕sorted .= forward * ts_sorted
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
        s .= real.(inverse * 𝓕new) # ifft normalises by default

        # map original values onto shuffle
        s[sortperm(s)] = x_sorted
        ts_sorted .= s

        # Convergence check on periodogram
        ps = DSP.periodogram(s)
        ps_binned = interp(ps.freq, ps.power, range)

        if iter == 1
            diffs[1] = sum((px_binned[2] .- ps_binned[2]).^2) / sum(px_binned[2].^2)
        else
            diffs[2] = sum((px_binned[2] .- ps_binned[2]).^2) / sum(px_binned[2].^2)
            abs(diffs[1] - diffs[2]) < tol ? break : diffs[1] = copy(diffs[2])
        end

        iter += 1
    end
    
    return s
end

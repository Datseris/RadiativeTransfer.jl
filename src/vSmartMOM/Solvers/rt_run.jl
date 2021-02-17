using ..Architectures: devi, default_architecture, AbstractArchitecture


function rt_run(pol_type,              # Polarization type (IQUV)
                obs_geom::ObsGeometry, # Solar Zenith, Viewing Zenith, Viewing Azimuthal 
                τRayl, ϖRayl,          # Rayleigh optical depth and single-scattering albedo
                τAer, ϖAer,            # Aerosol optical depth and single-scattering albedo
                qp_μ, wt_μ,            # Quadrature points and weights
                Ltrunc,                # Trunction length for legendre terms
                aerosol_optics,        # AerosolOptics (greek_coefs, ω̃, k, fᵗ)
                GreekRayleigh,         # Greek coefficients of Rayleigh Phase Function
                τ_abs,                 # nSpec x Nz matrix of absorption
                architecture::AbstractArchitecture) # Whether to use CPU / GPU

    #= 
    Define types, variables, and static quantities =#
    
    @unpack obs_alt, sza, vza, vaz = obs_geom   # Observational geometry properties
    FT = eltype(sza)                  # Get the float-type to use
    Nz = length(τRayl)                  # Number of vertical slices
    nSpec = size(τ_abs, 1)              # Number of spectral points
    μ0 = cosd(sza)                      # μ0 defined as cos(θ); θ = sza
    iμ0 = nearest_point(qp_μ, μ0)       # Find the closest point to μ0 in qp_μ
    arr_type = array_type(architecture)

    # Output variables: Reflected and transmitted solar irradiation at TOA and BOA respectively
    R = zeros(FT, length(vza), pol_type.n, nSpec)
    T = zeros(FT, length(vza), pol_type.n, nSpec)

    # Copy qp_μ "pol_type.n" times
    qp_μN = arr_type(repeat(qp_μ, pol_type.n))

    println("Processing on: ", architecture)
    println("With FT: ", FT)

    #= 
    Loop over number of truncation terms =#

    for m = 0:Ltrunc - 1

        println("Fourier Moment: ", m)

        # Azimuthal weighting
        weight = m == 0 ? FT(0.5) : FT(1.0)

        # Compute Z-moments of the Rayleigh phase matrix 
        # For m>=3, Rayleigh matrices will be 0, can catch with if statement if wanted 
        Rayl𝐙⁺⁺, Rayl𝐙⁻⁺ = Scattering.compute_Z_moments(pol_type, qp_μ, GreekRayleigh, m, arr_type = arr_type);

        # Number of aerosols
        nAer = length(aerosol_optics)
        dims = size(Rayl𝐙⁺⁺)
        
        # Compute aerosol Z-matrices for all aerosols
        Aer𝐙⁺⁺ = arr_type(zeros(FT, (dims[1], dims[2], nAer)))
        Aer𝐙⁻⁺ = similar(Aer𝐙⁺⁺)

        for i = 1:nAer
            Aer𝐙⁺⁺[:,:,i], Aer𝐙⁻⁺[:,:,i] = Scattering.compute_Z_moments(pol_type, qp_μ, aerosol_optics[i].greek_coefs, m, arr_type = arr_type)
        end

        # R and T matrices for Added and Composite Layers for this m

        added_layer = make_added_layer(FT, arr_type, dims, nSpec) 
        composite_layer = make_composite_layer(FT, arr_type, dims, nSpec)

        I_static = Diagonal(arr_type(Diagonal{FT}(ones(dims[1]))));

        scattering_interface = ScatteringInterface_00()

        # Loop over vertical layers:
        @showprogress 1 "Looping over layers ..." for iz = 1:Nz  # Count from TOA to BOA

            # Construct the atmospheric layer
            # From Rayleigh and aerosol τ, ϖ, compute overall layer τ, ϖ
            @timeit "Constructing" τ_λ, ϖ_λ, τ, ϖ, Z⁺⁺, Z⁻⁺ = construct_atm_layer(τRayl[iz], τAer[iz,:], ϖRayl[iz], ϖAer, aerosol_optics[1].fᵗ, Rayl𝐙⁺⁺, Rayl𝐙⁻⁺, Aer𝐙⁺⁺, Aer𝐙⁻⁺, τ_abs[:,iz], arr_type)

            # τ * ϖ should remain constant even though they individually change over wavelength
            # @assert all(i -> (i ≈ τ * ϖ), τ_λ .* ϖ_λ)

            # Compute doubling number
            dτ_max = minimum([τ * ϖ, FT(0.1) * minimum(qp_μ)])
            _, ndoubl = doubling_number(dτ_max, τ * ϖ)

            # Compute dτ vector
            dτ = arr_type(τ_λ ./ (FT(2)^ndoubl))
            
            # Determine whether there is scattering
            scatter = (  sum(τAer) > 1.e-8 || 
                      (( τRayl[iz] > 1.e-8 ) && (m < 3))) ? 
                      true : false

            # If there is scattering, perform the elemental and doubling steps
            if (scatter)
                @timeit "elemental" elemental!(pol_type, dτ, dτ_max, ϖ_λ, ϖ, Z⁺⁺, Z⁻⁺, m, ndoubl, scatter, qp_μ, wt_μ, added_layer,  I_static, arr_type, architecture)
                @timeit "doubling" doubling!(pol_type, ndoubl, added_layer, I_static, architecture)

            # If not, there is no reflectance. Assign r/t appropriately
            else
                added_layer.r⁻⁺, added_layer.r⁺⁻ = (0, 0)
                added_layer.t⁺⁺, added_layer.t⁻⁻ = (Diagonal(exp(-τ / qp_μN)), Diagonal(exp(-τ / qp_μN)))
            end

            # Whether there is scattering in the added layer, composite layer, neither or both
            scattering_interface = get_scattering_interface(scattering_interface, scatter, iz)

            # @assert !any(isnan.(added_layer.t⁺⁺))
            
            # If this TOA, just copy the added layer into the composite layer
            if (iz == 1)
                composite_layer.T⁺⁺[:], composite_layer.T⁻⁻[:] = (added_layer.t⁺⁺, added_layer.t⁻⁻)
                composite_layer.R⁻⁺[:], composite_layer.R⁺⁻[:] = (added_layer.r⁻⁺, added_layer.r⁺⁻)
            
            # If this is not the TOA, perform the interaction step
            else
                @timeit "interaction" interaction!(scattering_interface, composite_layer, added_layer, I_static)
            end
        end 

        # include surface function

        # idx of μ0 = cos(sza)
        st_iμ0, istart0, iend0 = get_indices(iμ0, pol_type)

        # Convert these to Arrays (if CuArrays), so they can be accessed by index
        R⁻⁺ = Array(composite_layer.R⁻⁺)
        T⁺⁺ = Array(composite_layer.T⁺⁺)

        # Loop over all viewing zenith angles
        for i = 1:length(vza)

            # Find the nearest quadrature point idx
            iμ = nearest_point(qp_μ, cosd(vza[i]))
            st_iμ, istart, iend = get_indices(iμ, pol_type)
            
            # Compute bigCS
            cos_m_phi, sin_m_phi = (cosd(m * vaz[i]), sind(m * vaz[i]))
            bigCS = weight * Diagonal([cos_m_phi, cos_m_phi, sin_m_phi, sin_m_phi][1:pol_type.n])

            # Accumulate Fourier moments after azimuthal weighting
            for s = 1:nSpec
                R[i,:,s] += bigCS * (R⁻⁺[istart:iend, istart0:iend0, s] / wt_μ[iμ0]) * pol_type.I0
                T[i,:,s] += bigCS * (T⁺⁺[istart:iend, istart0:iend0, s] / wt_μ[iμ0]) * pol_type.I0
            end
            
        end
    end

    print_timer()
    reset_timer!()

    return R, T  
end


function rt_run(model::vSmartMOM_Model)

    return rt_run(model.params.polarization_type,
                  model.obs_geom::ObsGeometry,
                  model.τRayl, model.ϖRayl,
                  model.τAer, model.ϖAer,
                  model.qp_μ, model.wt_μ,
                  model.params.max_m,
                  [model.aerosol_optics],
                  model.greek_rayleigh,
                  model.τ_abs,
                  model.params.architecture)
end
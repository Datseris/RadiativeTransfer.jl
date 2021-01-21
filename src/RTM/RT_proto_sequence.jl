using Revise
using Plots
using RadiativeTransfer
using RadiativeTransfer.CrossSection
using RadiativeTransfer.PhaseFunction
using RadiativeTransfer.RTM
using Distributions
using BenchmarkTools

FT = Float32
"Generate aerosol optical properties"

# Wavelength (just one for now)
λ = FT(0.770)       # Incident wavelength
depol = FT(0.0)
# Truncation 
Ltrunc = 6             # Truncation  
truncation_type   = PhaseFunction.δBGE{Float32}(Ltrunc, 2.0)

# polarization_type
polarization_type = Stokes_IQU{FT}()

# Quadrature points for RTM
Nquad, qp_μ, wt_μ = rt_set_streams(RTM.RadauQuad(), Ltrunc, FT(60.0), FT[0.0, 15.0, 30., 45., 60.])

# Aerosol particle distribution and properties
μ            = [1.3]    # [0.3,2.0]       # Log mean radius
σ            = [2.0]    # [2.0,1.8]       # Log stddev of radius
r_max        = [30.0]   # [30.0,30.0]     # Maximum radius
nquad_radius = [2500]   # [2500,2500]     # Number of quadrature points for integrating of size dist.
nᵣ           = [1.3]    # [1.3, 1.66]     # Real part of refractive index
nᵢ           = [0.00000001]  # [0.001,0.0003]  # Imag part of refractive index

# Aerosol vertical distribution profiles
p₀          = FT[30000.]  # [50000., 20000.] # Pressure peak [Pa]
σp          = FT[5000.]   # [5000., 2000.]   # Pressure peak width [Pa]

size_distribution = [LogNormal(log(μ[1]), log(σ[1]))] # [LogNormal(log(μ[1]), log(σ[1])), LogNormal(log(μ[2]), log(σ[2]))]

# Create the aerosols (needs to be generalized through loops):
aero1 = make_univariate_aerosol(size_distribution[1], r_max[1], nquad_radius[1], nᵣ[1], nᵢ[1])
# aero2 = make_univariate_aerosol(size_distribution[2], r_max[2], nquad_radius[2], nᵣ[2], nᵢ[2])

# Define some details, run aerosol optics
model_NAI2_aero1 = make_mie_model(NAI2(), aero1, λ, polarization_type, truncation_type)
aerosol_optics_NAI2_aero1 = compute_aerosol_optical_properties(model_NAI2_aero1);
# Truncate:
aerosol_optics_trunc_aero1 = PhaseFunction.truncate_phase(truncation_type, aerosol_optics_NAI2_aero1; reportFit=true)

# Define some details, run aerosol optics
# model_NAI2_aero2 = make_mie_model(NAI2(), aero2, λ, polarization_type, truncation_type)
# aerosol_optics_NAI2_aero2 = compute_aerosol_optical_properties(model_NAI2_aero2);
# Truncate:
# aerosol_optics_trunc_aero2 = PhaseFunction.truncate_phase(truncation_type, aerosol_optics_NAI2_aero2)

# Rayleigh Greek
GreekRayleigh = PhaseFunction.get_greek_rayleigh(depol)


# In[ ]:


vza = [60., 45., 30., 15., 0., 15., 30., 45., 60.]
vaz = [180., 180., 180., 180., 0., 0., 0., 0., 0.]
sza = 60.
Nquad, qp_μ, wt_μ = rt_set_streams(RTM.RadauQuad(), Ltrunc, sza, vza);


# In[ ]:


" Atmospheric Profiles, basics, needs to be refactore entirely"
file = "/net/fluo/data1/ftp/XYZT_ESE156/Data/MERRA300.prod.assim.inst6_3d_ana_Nv.20150613.hdf.nc4"   
timeIndex = 2 # There is 00, 06, 12 and 18 in UTC, i.e. 6 hourly data stacked together

# What latitude do we want? 
myLat = 34.1377;
myLon = -118.1253;

# Read profile (and generate dry/wet VCDs per layer)
profile_caltech_hr = RTM.read_atmos_profile(file, myLat, myLon, timeIndex);
profile_caltech = RTM.reduce_profile(20, profile_caltech_hr)
# Compute layer optical thickness for Rayleigh (surface pressure in hPa) 
τRayl =  RTM.getRayleighLayerOptProp(profile_caltech.psurf / 100, λ, depol, profile_caltech.vcd_dry);
ϖRayl = ones(length(τRayl))

# Compute Naer aerosol optical thickness profiles
τAer_1 = RTM.getAerosolLayerOptProp(1.0, p₀[1], σp[1], profile_caltech.p_levels)
# τAer_2 = RTM.getAerosolLayerOptProp(0.3, p₀[2], σp[2], profile_caltech.p_levels)

# Can be done with arbitrary length later:
τAer = 0.2 * τAer_1 # [τAer_1 τAer_2]
@show sum(τAer)# , sum(τAer_2)
ϖAer = [aerosol_optics_NAI2_aero1.ω̃] # [aerosol_optics_NAI2_aero1.ω̃ aerosol_optics_NAI2_aero2.ω̃];
fᵗ   = [aerosol_optics_trunc_aero1.fᵗ] # [aerosol_optics_trunc_aero1.fᵗ aerosol_optics_trunc_aero2.fᵗ];

aerosol_optics = [aerosol_optics_trunc_aero1] # [aerosol_optics_trunc_aero1 aerosol_optics_trunc_aero2]
# Aer𝐙⁺⁺ = [aero1_Z⁺⁺] # [aero1_Z⁺⁺, aero2_Z⁺⁺];
# Aer𝐙⁻⁺ = [aero1_Z⁻⁺] # [aero1_Z⁻⁺, aero2_Z⁻⁺];

maxM = 5

# function compute_absorption_profile!(grid,
#                                      τ_abs::Array{Float64,2}, 
#                                      profile::RadiativeTransfer.RTM.AtmosphericProfile)

#     @assert size(absorption_spectra)[2] == length(profile_caltech.p)

#     hitran_data = read_hitran(artifact("O2"), iso=1)
#     model = make_hitran_model(hitran_data, Voigt(), wing_cutoff = 40, CEF=HumlicekWeidemann32SDErrorFunction(), architecture=CrossSection.GPU())

#     for iz in 1:length(profile_caltech.p)

#         println(iz)

#         p = profile_caltech.p[iz]
#         T = profile_caltech.T[iz]

#         τ_abs[:,iz] = Array(absorption_cross_section(model, grid, p, T))
#     end

#     return nothing
    
# end


grid = range(1e7 / 764, 1e7 / 763, length=500)

τ_abs = zeros(length(grid), length(profile_caltech.p))
compute_absorption_profile!(grid, τ_abs, profile_caltech)

# anim = @animate for i ∈ length(profile_caltech.p):-1:1

#     # l = @layout [a ; b c]
#     # p1 = plot(...)
#     # p2 = plot(...)
#     # p3 = plot(...)
#     # plot(p1, p2, p3, layout = l)

#     p1 = plot(1:length(absorption[:,i]), absorption[:,i], ylims=(0, 4.5e-22), title=("O2 Absorption"))
#     p2 = plot(1:length(absorption[:,i]), absorption[:,i], ylims=(0, 1e-23), title=("O2 Absorption (zoomed in)"))
#     p3 = plot(1:length(profile_caltech.p[end:-1:i]), 
#               profile_caltech.p[end:-1:i], 
#               xlims=(0,length(profile_caltech.p)), 
#               ylims=(1, 100000), 
#               yaxis=:log,
#               title=("Pressure (Pa)"))

#     p4 = plot(1:length(profile_caltech.T[end:-1:i]), 
#               profile_caltech.T[end:-1:i], 
#               xlims=(0,length(profile_caltech.T)), 
#               ylims=(150, 300), 
#               title=("Temperature (K)"))
#     # p4 = 

#     plot(p1, p2, p3, p4, layout = 4, legend=false)
# end
# gif(anim, "anim_fps15.gif", fps = 15)

R, T = RTM.run_RTM(polarization_type, sza, vza, vaz, τRayl, ϖRayl, τAer, ϖAer, fᵗ, qp_μ, wt_μ, maxM, aerosol_optics, GreekRayleigh, τ_abs);

# RTM.run_RTM(polarization_type, sza, vza, vaz, τRayl, ϖRayl, τAer, ϖAer, fᵗ, qp_μ, wt_μ, maxM, aerosol_optics, GreekRayleigh, τ_abs);

# R ≈ R_true
# T ≈ T_true

a = 1
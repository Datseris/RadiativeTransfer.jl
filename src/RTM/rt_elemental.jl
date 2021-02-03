"Elemental single-scattering layer"
function rt_elemental_helper!(pol_type, 
                              dτ_λ::AbstractArray{FT,1}, 
                              dτ::FT, 
                              ϖ_λ::AbstractArray{FT,1}, 
                              ϖ::FT, 
                              Z⁺⁺::AbstractArray{FT,2}, 
                              Z⁻⁺::AbstractArray{FT,2}, 
                              m::Int, 
                              ndoubl::Int, 
                              scatter, 
                              qp_μ::AbstractArray{FT,1}, 
                              wt_μ::AbstractArray{FT,1}, 
                              added_layer::AddedLayer{FT}, 
                              I_static,
                              arr_type,
                              architecture) where {FT}
    
    @unpack r⁺⁻, r⁻⁺, t⁻⁻, t⁺⁺ = added_layer
    # @show FT
    # ToDo: Main output is r⁺⁻, r⁻⁺, t⁻⁻, t⁺⁺ (can be renamed to t⁺⁺, etc)
    # Need to check with paper nomenclature. This is basically eqs. 19-20 in vSmartMOM

    # dτ: optical depth of elemental layer
    # ϖ: single scattering albedo of elemental layer
    # bb: thermal source function at the upper boundary of the elemental layer
    # m: fourier moment
    # n: layer of which this is an elemental
    # ndoubl: number of doubling computations needed to progress from the elemental layer 
    #         to the full homogeneous layer n
    # scatter: flag indicating scattering

    Z⁺⁺_ = repeat(Z⁺⁺, 1, 1, 1)
    Z⁻⁺_ = repeat(Z⁻⁺, 1, 1, 1)

    device = devi(architecture)

    if scatter
        qp_μN = arr_type(reduce(vcat, (fill.(qp_μ, [pol_type.n]))))
        wt_μN = arr_type(reduce(vcat, (fill.(wt_μ, [pol_type.n]))))

        NquadN = length(qp_μN)

        wct = m == 0 ? FT(0.50) * ϖ * wt_μN  : FT(0.25) * ϖ * wt_μN
        wct2 = m == 0 ? wt_μN  : wt_μN / 2
        # wct = m==0 ? 0.50 * 1 .* wt_μ4  : 0.25 .* 1 .* wt_μ4

        # Get the diagonal matrices first
        d_qp  = Diagonal(arr_type(1 ./ qp_μN))
        d_wct = Diagonal(arr_type(wct))

        # Calculate r⁻⁺ and t⁺⁺
        
        # Version 1: no absorption in batch mode (like before), need to separate these modes
        if maximum(dτ) < 0.0001 

            r⁻⁺[:,:,:] .= d_qp * Z⁻⁺ * (d_wct * dτ)
            t⁺⁺[:,:,:] .= I_static - (d_qp * ((I_static - Z⁺⁺ * d_wct) * dτ))
        
        else    
        # Version 2: with absorption in batch mode, low tau_scatt but higher tau_total, needs different equations
        # This is not yet GPU ready as it has element wise operations (should work for CPU)

            kernel! = get_r!(device)
            event = kernel!(r⁻⁺, r⁺⁻, t⁺⁺, t⁻⁻, ϖ_λ, dτ_λ, Z⁻⁺, Z⁺⁺, qp_μN, wct2, ndoubl, pol_type.n, ndrange=size(r⁻⁺));
            wait(device, event)
            synchronize()
        end

        
    else 
        # Note: τ is not defined here
        t⁺⁺[:] = Diagonal{exp(-τ ./ qp_μN)}
        t⁻⁻[:] = Diagonal{exp(-τ ./ qp_μN)}
    end    

end

@kernel function get_r!(r⁻⁺, r⁺⁻, t⁺⁺, t⁻⁻, ϖ_λ, dτ_λ, Z⁻⁺, Z⁺⁺, qp_μ4, wct2, ndoubl, pol_type_n)
    i, j, n = @index(Global, NTuple)

    # 𝐑⁻⁺(μᵢ, μⱼ) = ϖ ̇𝐙⁻⁺(μᵢ, μⱼ) ̇(μⱼ/(μᵢ+μⱼ)) ̇(1 - exp{-τ ̇(1/μᵢ + 1/μⱼ)}) ̇𝑤ⱼ
    r⁻⁺[i,j,n] = ϖ_λ[n] * Z⁻⁺[i,j] * (qp_μ4[j] / (qp_μ4[i] + qp_μ4[j])) * (1 - exp.(-dτ_λ[n] * ((1 / qp_μ4[i]) + (1 / qp_μ4[j])))) * (wct2[j]) 
                    
    if (qp_μ4[i] == qp_μ4[j])

        # 𝐓⁺⁺(μᵢ, μᵢ) = (exp{-τ/μᵢ} + ϖ ̇𝐙⁺⁺(μᵢ, μᵢ) ̇(τ/μᵢ) ̇exp{-τ/μᵢ}) ̇𝑤ᵢ
        if i == j
            t⁺⁺[i,j,n] = exp(-dτ_λ[n] / qp_μ4[i]) + ϖ_λ[n] * Z⁺⁺[i,i] * (dτ_λ[n] / qp_μ4[i]) * exp.(-dτ_λ[n] / qp_μ4[i]) * wct2[i]
        else
            t⁺⁺[i,j,n] = ϖ_λ[n] * Z⁺⁺[i,i] * (dτ_λ[n] / qp_μ4[i]) * exp.(-dτ_λ[n] / qp_μ4[i]) * wct2[i]
        end
    else
    
        # 𝐓⁺⁺(μᵢ, μⱼ) = ϖ ̇𝐙⁺⁺(μᵢ, μⱼ) ̇(μⱼ/(μᵢ-μⱼ)) ̇(exp{-τ/μᵢ} - exp{-τ/μⱼ}) ̇𝑤ⱼ
        # (𝑖 ≠ 𝑗)
        t⁺⁺[i,j,n] = ϖ_λ[n] * Z⁺⁺[i,j] * (qp_μ4[j] / (qp_μ4[i] - qp_μ4[j])) * (exp(-dτ_λ[n] / qp_μ4[i]) - exp(-dτ_λ[n] / qp_μ4[j])) * wct2[j]
    end
    if ndoubl < 1
        ii = mod(i - 1, pol_type_n)
        jj = mod(j - 1, pol_type_n)
        if ((ii <= 1) & (jj <= 1)) | ((ii >= 2) & (jj >= 2))
            r⁺⁻[i,j,n] = r⁻⁺[i,j,n]
            t⁻⁻[i,j,n] = t⁺⁺[i,j,n]
        else
            r⁺⁻[i,j,n] = r⁻⁺[i,j,n]
            t⁻⁻[i,j,n] = t⁺⁺[i,j,n]
        end
    else
        if mod(i - 1, pol_type_n) >= 2
            r⁻⁺[i,j,n] = - r⁻⁺[i,j,n]
        end
    end
end



function rt_elemental!(pol_type, dτ_λ, dτ, ϖ_λ, ϖ, Z⁺⁺, Z⁻⁺, m, 
                              ndoubl, scatter, qp_μ, wt_μ, 
                              added_layer::AddedLayer{FT}, 
                              I_static,
                              arr_type,
                              architecture) where {FT}

    rt_elemental_helper!(pol_type, dτ_λ, dτ, ϖ_λ, ϖ, Z⁺⁺, Z⁻⁺, m, ndoubl, scatter, qp_μ, wt_μ, added_layer, I_static, arr_type, architecture)
    synchronize()
end
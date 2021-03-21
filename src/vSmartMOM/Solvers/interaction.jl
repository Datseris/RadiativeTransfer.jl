# No scattering in either the added layer or the composite layer.
function interaction_helper!(::ScatteringInterface_00, SFI,
                                composite_layer::CompositeLayer{FT}, 
                                added_layer::AddedLayer{FT}, 
                                I_static::AbstractArray{FT}) where {FT}

    if SFI
        composite_layer.J₀⁺ = added_layer.J₀⁺ + added_layer.t⁺⁺ ⊠ composite_layer.J₀⁺
        composite_layer.J₀⁻ = composite_layer.J₀⁻ + composite_layer.T⁻⁻ ⊠ added_layer.J₀⁻
    end
    composite_layer.T⁻⁻[:] = added_layer.t⁻⁻ ⊠ composite_layer.T⁻⁻
    composite_layer.T⁺⁺[:] = added_layer.t⁺⁺ ⊠ composite_layer.T⁺⁺
end

# No scattering in inhomogeneous composite layer.
# Scattering in homogeneous layer, added to bottom of the composite layer.
# Produces a new, scattering composite layer.
function interaction_helper!(::ScatteringInterface_01, SFI,
                                composite_layer::CompositeLayer{FT}, 
                                added_layer::AddedLayer{FT}, 
                                I_static::AbstractArray{FT}) where {FT}

    if SFI
       composite_layer.J₀⁻ = composite_layer.T⁻⁻ ⊠ (added_layer.r⁻⁺ ⊠ composite_layer.J₀⁺ + added_layer.J₀⁻) 
       composite_layer.J₀⁺ = added_layer.J₀⁺ + added_layer.t⁺⁺ ⊠ composite_layer.J₀⁺ 
    end
    composite_layer.R⁻⁺[:] = composite_layer.T⁻⁻ * added_layer.r⁻⁺ * composite_layer.T⁺⁺
    composite_layer.R⁺⁻[:] = added_layer.r⁺⁻
    composite_layer.T⁺⁺[:] = added_layer.t⁺⁺ * composite_layer.T⁺⁺
    composite_layer.T⁻⁻[:] = composite_layer.T⁻⁻ * added_layer.t⁻⁻

    
end

# Scattering in inhomogeneous composite layer.
# no scattering in homogeneous layer which is 
# added to the bottom of the composite layer.
# Produces a new, scattering composite layer.
function interaction_helper!(::ScatteringInterface_10, SFI,
                                composite_layer::CompositeLayer{FT}, 
                                added_layer::AddedLayer{FT}, 
                                I_static::AbstractArray{FT}) where {FT}

    if SFI
        composite_layer.J₀⁺ = added_layer.J₀⁺ + added_layer.t⁺⁺ ⊠ composite_layer.J₀⁺
        composite_layer.J₀⁻ = composite_layer.J₀⁻
    end
    composite_layer.T⁺⁺[:] = added_layer.t⁺⁺ * composite_layer.T⁺⁺
    composite_layer.T⁻⁻[:] = composite_layer.T⁻⁻ * added_layer.t⁻⁻
    composite_layer.R⁺⁻[:] = added_layer.t⁺⁺ * composite_layer.R⁺⁻ * added_layer.t⁻⁻
end

# Scattering in inhomogeneous composite layer.
# Scattering in homogeneous layer which is added to the bottom of the composite layer.
# Produces a new, scattering composite layer.
function interaction_helper!(::ScatteringInterface_11, SFI,
                                composite_layer::CompositeLayer{FT}, 
                                added_layer::AddedLayer{FT}, 
                                I_static::AbstractArray{FT}) where {FT}
    
    @unpack r⁺⁻, r⁻⁺, t⁻⁻, t⁺⁺ = added_layer
    @unpack R⁻⁺, R⁺⁻, T⁺⁺, T⁻⁻, J₀⁺, J₀⁻ = composite_layer

    # Used to store `(I - R⁺⁻ * r⁻⁺)⁻¹ * T⁺⁺`
    tmp_inv = similar(t⁺⁺)

    # Compute and store `(I - R⁺⁻ * r⁻⁺)⁻¹ * T⁺⁺`
    @timeit "interaction inv1" batch_inv!(tmp_inv, I_static .- R⁺⁻ ⊠ r⁻⁺) #Suniti
    # Temporary arrays:
    # T₂₁(I-R₀₁R₂₁)⁻¹
    T21_inv = T⁻⁻ ⊠ tmp_inv;
    # T₀₁(I-R₀₁R₂₁)⁻¹
    T01_inv = t⁺⁺ ⊠ tmp_inv 
    composite_layer.R⁻⁺[:] = R⁻⁺ + T01_inv ⊠ r⁻⁺ ⊠ T⁺⁺ #Suniti
    composite_layer.T⁺⁺[:] = T01_inv  ⊠ T⁺⁺ #Suniti
    #composite_layer.J₀⁺[:] = J₀⁺ + t⁺⁺ ⊠ tmp_inv ⊠ (R⁺⁻ ⊠ J₀⁻ + J₀⁺)
    if SFI
        composite_layer.J₀⁺[:] = added_layer.J₀⁺ + T01_inv ⊠ (R⁺⁻ ⊠ added_layer.J₀⁻ + J₀⁺)
        #for nλ=1:size(J₀⁺,3)     
        #    composite_layer.J₀⁺[:,1,nλ] = added_layer.J₀⁺[:,1,nλ] + t⁺⁺[:,:,nλ] * tmp_inv[:,:,nλ] * (R⁺⁻[:,:,nλ] * added_layer.J₀⁻[:,1,nλ] + J₀⁺[:,1,nλ])
        #end 
    end 
    # Repeating for mirror-reflected directions

    # Compute and store `(I - r⁻⁺ * R⁺⁻)⁻¹ * t⁻⁻`
    @timeit "interaction inv2" batch_inv!(tmp_inv, I_static .- r⁻⁺ ⊠ R⁺⁻) #Suniti

    composite_layer.R⁺⁻[:] = r⁺⁻ + T01_inv ⊠ R⁺⁻ ⊠ t⁻⁻ #Suniti
    composite_layer.T⁻⁻[:] = T⁺⁺ ⊠ tmp_inv ⊠ t⁻⁻ #Suniti

    if SFI
        composite_layer.J₀⁻[:] = J₀⁻ + T21_inv ⊠ (r⁻⁺ ⊠ J₀⁻ + added_layer.J₀⁻)
        #for nλ=1:size(J₀⁺,3)
        #    composite_layer.J₀⁻[:,1,nλ] = J₀⁻[:,1,nλ] + T⁻⁻[:,:,nλ] * tmp_inv[:,:,nλ] * (r⁻⁺[:,:,nλ] * J₀⁺[:,1,nλ] + added_layer.J₀⁻[:,1,nλ])
        #end
    end 

    #@pack! composite_layer = R⁻⁺, R⁺⁻, T⁺⁺, T⁻⁻, J₀⁺, J₀⁻
end


function interaction!(scattering_interface::AbstractScatteringInterface, SFI,
                        composite_layer::CompositeLayer{FT}, 
                        added_layer::AddedLayer{FT},
                        I_static::AbstractArray{FT}) where {FT}

    interaction_helper!(scattering_interface, SFI, composite_layer, added_layer, I_static)
    ### synchronize()
    
end
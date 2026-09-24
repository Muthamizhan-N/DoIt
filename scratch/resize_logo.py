import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

def create_perfect_resized_logo(scale_factor=0.83, output_path='assets/launcher_icon/doit_logo_fixed.png'):
    # Load pristine original image
    img = Image.open('assets/launcher_icon/doit_logo.png').convert('RGB')
    arr = np.array(img, dtype=float)
    h, w, _ = arr.shape

    # 1. Fit smooth background gradient across 1024x1024 canvas using outer border pixels
    # Outer 100 pixels on all sides are 100% background gradient in original image
    border_mask = np.zeros((h, w), dtype=bool)
    border_mask[:80, :] = True
    border_mask[-80:, :] = True
    border_mask[:, :80] = True
    border_mask[:, -80:] = True

    X_flat = np.repeat(np.arange(w)[None, :], h, axis=0)[border_mask]
    Y_flat = np.repeat(np.arange(h)[:, None], w, axis=1)[border_mask]

    # Use 3rd order polynomial surface fit for RGB background channels
    A = np.column_stack([
        np.ones_like(X_flat),
        X_flat / w,
        Y_flat / h,
        (X_flat / w)**2,
        (Y_flat / h)**2,
        (X_flat / w) * (Y_flat / h),
        (X_flat / w)**3,
        (Y_flat / h)**3,
        ((X_flat / w)**2) * (Y_flat / h),
        (X_flat / w) * ((Y_flat / h)**2)
    ])

    full_grid_x = np.repeat(np.arange(w)[None, :], h, axis=0)
    full_grid_y = np.repeat(np.arange(h)[:, None], w, axis=1)
    A_full = np.column_stack([
        np.ones((h*w,)),
        (full_grid_x / w).ravel(),
        (full_grid_y / h).ravel(),
        ((full_grid_x / w)**2).ravel(),
        ((full_grid_y / h)**2).ravel(),
        ((full_grid_x / w) * (full_grid_y / h)).ravel(),
        ((full_grid_x / w)**3).ravel(),
        ((full_grid_y / h)**3).ravel(),
        (((full_grid_x / w)**2) * (full_grid_y / h)).ravel(),
        ((full_grid_x / w) * ((full_grid_y / h)**2)).ravel()
    ])

    fitted_bg = np.zeros((h, w, 3))
    for ch in range(3):
        vals = arr[:,:,ch][border_mask]
        coeff, _, _, _ = np.linalg.lstsq(A, vals, rcond=None)
        fitted_bg[:,:,ch] = np.clip((A_full @ coeff).reshape((h, w)), 0, 255)

    # 2. Resize original image down by scale_factor
    new_w = int(w * scale_factor)
    new_h = int(h * scale_factor)
    resized_orig = img.resize((new_w, new_h), Image.Resampling.LANCZOS)
    resized_arr = np.array(resized_orig, dtype=float)

    # Calculate padding offsets
    pad_x = (w - new_w) // 2
    pad_y = (h - new_h) // 2

    # 3. Seamless blending mask
    # Create smooth radial/rectangular blend mask around the scaled image edges
    # Inside the core of scaled_arr (where the graphic lives), weight = 1.0 (use scaled image)
    # Near the edges of scaled_arr (which is just background), weight transitions smoothly to 0.0 (use fitted background)
    
    mask_scaled = np.ones((new_h, new_w), dtype=float)
    fade = int(min(new_w, new_h) * 0.15) # 15% fade margin along edges
    for i in range(fade):
        val = (i + 1) / float(fade)
        val = 0.5 - 0.5 * np.cos(np.pi * val) # Smooth cosine ease
        mask_scaled[i, :] = np.minimum(mask_scaled[i, :], val)
        mask_scaled[new_h - 1 - i, :] = np.minimum(mask_scaled[new_h - 1 - i, :], val)
        mask_scaled[:, i] = np.minimum(mask_scaled[:, i], val)
        mask_scaled[:, new_w - 1 - i] = np.minimum(mask_scaled[:, new_w - 1 - i], val)

    # Place onto 1024x1024 canvas
    composite = fitted_bg.copy()
    for ch in range(3):
        bg_crop = composite[pad_y:pad_y+new_h, pad_x:pad_x+new_w, ch]
        fg_crop = resized_arr[:, :, ch]
        blended = fg_crop * mask_scaled + bg_crop * (1.0 - mask_scaled)
        composite[pad_y:pad_y+new_h, pad_x:pad_x+new_w, ch] = blended

    final_img = Image.fromarray(np.uint8(np.clip(composite, 0, 255)), 'RGB')
    final_img.save(output_path, quality=98)
    print(f"Perfect logo created at {output_path} with scale {scale_factor}")

if __name__ == '__main__':
    create_perfect_resized_logo(scale_factor=0.83, output_path='assets/launcher_icon/doit_logo_fixed.png')

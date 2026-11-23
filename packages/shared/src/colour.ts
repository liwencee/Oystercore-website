// Turns a company's brand colour into two text colours that stay readable (WCAG 2.x AA, 4.5:1).

export class InvalidColourError extends Error {
  constructor(input: string) {
    super(
      `Invalid colour ${JSON.stringify(input)}: expected "#" followed by six hex digits, such as "#1D4ED8".`,
    );
    this.name = 'InvalidColourError';
  }
}

export type DerivedAccent = {
  /** The brand colour, uppercased. */
  brand: string;
  /** Text colour for use on the brand colour: the first of white, deep navy and black that reaches 4.5:1. */
  onAccent: '#FFFFFF' | '#0B1F3A' | '#000000';
  /** The brand colour darkened, with the same hue and saturation, until it reaches 4.5:1 as text on white. */
  accentOnWhite: string;
};

const WHITE = '#FFFFFF' as const;
const NAVY = '#0B1F3A' as const;
const BLACK = '#000000' as const;

const MIN_CONTRAST = 4.5;
const HEX_COLOUR = /^#[0-9a-fA-F]{6}$/;

type Rgb = readonly [red: number, green: number, blue: number];
type Hsl = { hue: number; saturation: number; lightness: number };

function parseHex(hex: string): Rgb {
  if (!HEX_COLOUR.test(hex)) {
    throw new InvalidColourError(hex);
  }
  return [
    parseInt(hex.slice(1, 3), 16),
    parseInt(hex.slice(3, 5), 16),
    parseInt(hex.slice(5, 7), 16),
  ];
}

function toHex([red, green, blue]: Rgb): string {
  const digits = [red, green, blue].map((channel) => channel.toString(16).padStart(2, '0'));
  return `#${digits.join('')}`.toUpperCase();
}

function relativeLuminance([red, green, blue]: Rgb): number {
  const linear = (channel: number): number => {
    const value = channel / 255;
    return value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue);
}

/** The WCAG contrast ratio between two `#RRGGBB` colours, from 1 (identical) to 21 (black on white). */
export function contrast(a: string, b: string): number {
  const first = relativeLuminance(parseHex(a));
  const second = relativeLuminance(parseHex(b));
  return (Math.max(first, second) + 0.05) / (Math.min(first, second) + 0.05);
}

function rgbToHsl([red, green, blue]: Rgb): Hsl {
  const r = red / 255;
  const g = green / 255;
  const b = blue / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const delta = max - min;
  const lightness = (max + min) / 2;
  if (delta === 0) {
    return { hue: 0, saturation: 0, lightness };
  }
  const saturation = delta / (1 - Math.abs(2 * lightness - 1));
  let sector: number;
  if (max === r) {
    sector = ((g - b) / delta) % 6;
  } else if (max === g) {
    sector = (b - r) / delta + 2;
  } else {
    sector = (r - g) / delta + 4;
  }
  return { hue: (sector * 60 + 360) % 360, saturation, lightness };
}

function hslToRgb({ hue, saturation, lightness }: Hsl): Rgb {
  const spread = saturation * Math.min(lightness, 1 - lightness);
  const channel = (offset: number): number => {
    const k = (offset + hue / 30) % 12;
    const value = lightness - spread * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    return Math.round(value * 255);
  };
  return [channel(0), channel(8), channel(4)];
}

function darkenUntilReadableOnWhite(brand: string): string {
  if (contrast(brand, WHITE) >= MIN_CONTRAST) {
    return brand;
  }
  const hsl = rgbToHsl(parseHex(brand));
  // Lightness falls to 0 (black, 21:1 on white) at the latest, so this always returns.
  for (let step = 1; ; step += 1) {
    const lightness = Math.max(0, hsl.lightness - step * 0.01);
    const candidate = toHex(hslToRgb({ ...hsl, lightness }));
    if (contrast(candidate, WHITE) >= MIN_CONTRAST) {
      return candidate;
    }
  }
}

/** Derives the accessible text colours for a brand colour given as `#RRGGBB` (any case). */
export function deriveAccent(hex: string): DerivedAccent {
  parseHex(hex);
  const brand = hex.toUpperCase();
  // White and black cannot both fall short of 4.5:1, so black is a safe last resort.
  const onAccent = [WHITE, NAVY].find((text) => contrast(text, brand) >= MIN_CONTRAST) ?? BLACK;
  return { brand, onAccent, accentOnWhite: darkenUntilReadableOnWhite(brand) };
}

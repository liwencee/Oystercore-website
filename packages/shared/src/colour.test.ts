import { describe, expect, it } from 'vitest';
import { contrast, deriveAccent, InvalidColourError } from './colour.js';

const WHITE = '#FFFFFF';
const NAVY = '#0B1F3A';
const BLACK = '#000000';
const MIN_RATIO = 4.5;

const PROTOTYPE_SAMPLES = [
  '#1D4ED8',
  '#0F766E',
  '#B45309',
  '#7C3AED',
  '#BE123C',
  '#15803D',
  '#0369A1',
  '#A16207',
  '#C2410C',
  '#475569',
];

describe('contrast', () => {
  it('is 21 between white and black, in either order', () => {
    expect(contrast(WHITE, BLACK)).toBeCloseTo(21, 1);
    expect(contrast(BLACK, WHITE)).toBeCloseTo(21, 1);
  });

  it('is 1 between a colour and itself', () => {
    expect(contrast('#1D4ED8', '#1d4ed8')).toBeCloseTo(1, 5);
  });

  it('rejects a malformed colour', () => {
    expect(() => contrast('#fff', BLACK)).toThrow(InvalidColourError);
    expect(() => contrast(WHITE, 'black')).toThrow(InvalidColourError);
  });
});

describe('deriveAccent', () => {
  it('uppercases the brand colour', () => {
    expect(deriveAccent('#ffff00').brand).toBe('#FFFF00');
    expect(deriveAccent('#1d4ed8')).toEqual(deriveAccent('#1D4ED8'));
  });

  it('uses navy text on bright yellow and keeps the accent readable on white', () => {
    const accent = deriveAccent('#ffff00');
    expect(accent.onAccent).toBe(NAVY);
    expect(contrast(accent.accentOnWhite, WHITE)).toBeGreaterThanOrEqual(MIN_RATIO);
  });

  it('keeps the hue when darkening: yellow stays yellow, with no blue', () => {
    const { accentOnWhite } = deriveAccent('#FFFF00');
    expect(accentOnWhite).toMatch(/^#[0-9A-F]{6}$/);
    expect(accentOnWhite).not.toBe('#FFFF00');
    expect(accentOnWhite.slice(1, 3)).toBe(accentOnWhite.slice(3, 5));
    expect(accentOnWhite.slice(5, 7)).toBe('00');
  });

  it('falls back to black text on a mid grey that neither white nor navy suits', () => {
    const accent = deriveAccent('#808080');
    expect(contrast(WHITE, '#808080')).toBeLessThan(MIN_RATIO);
    expect(contrast(NAVY, '#808080')).toBeLessThan(MIN_RATIO);
    expect(accent.onAccent).toBe(BLACK);
  });

  it('prefers white text, then navy, then black, whichever reaches 4.5:1 first', () => {
    expect(deriveAccent('#1D4ED8').onAccent).toBe(WHITE);
    expect(deriveAccent('#FFFF00').onAccent).toBe(NAVY);
    expect(deriveAccent('#808080').onAccent).toBe(BLACK);
  });

  it.each(PROTOTYPE_SAMPLES)('keeps both derived colours readable for %s', (brand) => {
    const accent = deriveAccent(brand);
    expect(accent.brand).toBe(brand);
    expect(contrast(accent.onAccent, accent.brand)).toBeGreaterThanOrEqual(MIN_RATIO);
    expect(contrast(accent.accentOnWhite, WHITE)).toBeGreaterThanOrEqual(MIN_RATIO);
  });

  it.each([WHITE, BLACK])('handles the extreme brand colour %s', (brand) => {
    const accent = deriveAccent(brand);
    expect(contrast(accent.onAccent, accent.brand)).toBeGreaterThanOrEqual(MIN_RATIO);
    expect(contrast(accent.accentOnWhite, WHITE)).toBeGreaterThanOrEqual(MIN_RATIO);
  });

  it('gives a white brand navy text and a black brand white text', () => {
    expect(deriveAccent(WHITE).onAccent).toBe(NAVY);
    expect(deriveAccent(BLACK).onAccent).toBe(WHITE);
  });

  it('returns the brand unchanged as the accent when it already reaches 4.5:1 on white', () => {
    expect(deriveAccent('#0f766e').accentOnWhite).toBe('#0F766E');
    expect(deriveAccent(BLACK).accentOnWhite).toBe(BLACK);
  });

  it('treats 4.5:1 as the pass mark, just either side of it', () => {
    // #767676 is the lightest grey that passes on white (4.54:1); #777777 just misses (4.48:1).
    const passing = deriveAccent('#767676');
    expect(contrast('#767676', WHITE)).toBeGreaterThanOrEqual(MIN_RATIO);
    expect(passing.onAccent).toBe(WHITE);
    expect(passing.accentOnWhite).toBe('#767676');

    const failing = deriveAccent('#777777');
    expect(contrast('#777777', WHITE)).toBeLessThan(MIN_RATIO);
    expect(failing.onAccent).not.toBe(WHITE);
    expect(failing.accentOnWhite).not.toBe('#777777');
    expect(contrast(failing.accentOnWhite, WHITE)).toBeGreaterThanOrEqual(MIN_RATIO);
  });

  it('darkens in 1% lightness steps and stops at the first one that passes', () => {
    // #777777 is HSL lightness 46.67%. One 1% step down is 45.67%, which rounds to #747474 (4.67:1).
    expect(deriveAccent('#777777').accentOnWhite).toBe('#747474');
  });

  it.each(['#fff', 'red', '#GGGGGG', '', ' #FFFFFF', '#FFFFFF ', '#FFFFFF\n', 'FFFFFF', '#FFFFFFFF'])(
    'throws InvalidColourError for %j',
    (input) => {
      expect(() => deriveAccent(input)).toThrow(InvalidColourError);
    },
  );

  it('names the offending input in the error message', () => {
    expect(() => deriveAccent('#fff')).toThrow(/"#fff"/);
    expect(() => deriveAccent(' #FFFFFF')).toThrow(/" #FFFFFF"/);
  });

  it('is an Error subclass with a recognisable name', () => {
    try {
      deriveAccent('red');
      expect.unreachable('deriveAccent should have thrown');
    } catch (error) {
      expect(error).toBeInstanceOf(Error);
      expect(error).toBeInstanceOf(InvalidColourError);
      expect((error as Error).name).toBe('InvalidColourError');
    }
  });
});

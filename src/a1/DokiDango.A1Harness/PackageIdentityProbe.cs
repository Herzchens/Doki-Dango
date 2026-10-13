using System.Runtime.InteropServices;
using System.Text;

namespace DokiDango.A1Harness;

internal static class PackageIdentityProbe
{
    private const int ErrorInsufficientBuffer = 122;
    private const int AppModelErrorNoPackage = 15700;

    public static PackageIdentityResult Detect()
    {
        var length = 0;
        var first = GetCurrentPackageFullName(ref length, null);

        if (first == AppModelErrorNoPackage)
        {
            return new PackageIdentityResult("unpackaged", null, first);
        }

        if (first != ErrorInsufficientBuffer || length <= 0)
        {
            return new PackageIdentityResult("unknown", null, first);
        }

        var buffer = new StringBuilder(length);
        var second = GetCurrentPackageFullName(ref length, buffer);

        return second == 0
            ? new PackageIdentityResult("packaged", buffer.ToString(), second)
            : new PackageIdentityResult("unknown", null, second);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetCurrentPackageFullName(
        ref int packageFullNameLength,
        StringBuilder? packageFullName);
}

internal sealed record PackageIdentityResult(string PackageForm, string? PackageFullName, int Win32Result);

#include "numpy_order.hpp"
#include <iostream>
int main() {
    int n;
    while (std::cin >> n) {
        if (n < 0 || n > 3000)
            return 1;
        std::vector<double> values(n);
        for (auto &v : values)
            if (!(std::cin >> v))
                return 1;
        auto order = textpicker::numpy_order(values);
        for (size_t i = 0; i < order.size(); ++i)
            std::cout << (i ? " " : "") << order[i];
        std::cout << '\n';
    }
}

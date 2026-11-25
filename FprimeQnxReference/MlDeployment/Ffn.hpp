#ifndef M4_FFN_HPP
#define M4_FFN_HPP

#include <cstddef>
#include <memory>

namespace M4 {

enum class Features { AdcsBias, AdcsDrift, OpsSatSegment };

struct Prediction {
    double score;
    bool alert;
};

class Ffn {
  public:
    Ffn(const char* path, Features features);
    ~Ffn();

    std::size_t inputCount() const;
    Prediction predict(const double* features, std::size_t count);

  private:
    class Model;
    std::unique_ptr<Model> m_model;
};

}  // namespace M4

#endif
